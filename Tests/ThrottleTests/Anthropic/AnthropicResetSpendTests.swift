import XCTest
@testable import Throttle

/// Spending a chosen Claude reset kind through the real adapter: the kind is
/// resolved to one of its own grants at the click, never replaced by another
/// kind, never sent while blocked, and an unanswered attempt keeps its grant.
/// Also the diagnostics lines the reset block and a failed reset leave.
final class AnthropicResetSpendTests: XCTestCase {
    private let start = Date.iso("2026-07-13T12:00:00Z")
    /// Marker ids: none of them may survive in a diagnostics line.
    private let markerOrganization = "7e57ab1e-0000-4000-8000-00000000cafe"
    private let markerAttempt = UUID(uuidString: "5E17E1E1-0000-4000-8000-0000000000AA")!
    private let markerGrant = "grant-sentinel-1"

    private let account = Account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, provider: .anthropic, email: "user@example.com", sortIndex: 0)
    private let credential = AccountCredential(
        accessToken: AnthropicSampleSecret.accessToken,
        refreshToken: AnthropicSampleSecret.refreshToken,
        expiresAt: nil,
        accountID: "acct_test",
        scopes: ["user:profile", "user:inference"]
    )

    private var markerProfile: Data {
        Data(#"{"organization":{"uuid":"\#(markerOrganization)","organization_type":"claude_max"}}"#.utf8)
    }

    private var resetURL: URL {
        URL(string: "https://api.anthropic.com/api/organizations/\(markerOrganization)/reset_rate_limits")!
    }

    /// The kinds fixture with its reset block edited by `edit`.
    private func kindsBody(_ edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-resets-kinds")) as? [String: Any])
        var block = try XCTUnwrap(root[AnthropicResetParser.blockKey] as? [String: Any])
        var grants = try XCTUnwrap(block["grants"] as? [[String: Any]])
        edit(&grants)
        block["grants"] = grants
        root[AnthropicResetParser.blockKey] = block
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A provider that has read `body` once (usage, then the profile).
    private func readProvider(
        _ client: AnthropicMockHTTPClient,
        body: Data,
        clock: MovableNow? = nil,
        diagnostics: Diagnostics? = nil
    ) async throws -> AnthropicProvider {
        client.enqueue(status: 200, body: body)
        client.enqueue(status: 200, body: markerProfile)
        let clock = clock ?? MovableNow(start)
        let provider = AnthropicProvider(client: client, now: { clock.now }, diagnostics: diagnostics)
        _ = try await provider.fetchStatus(account: account, credential: credential)
        return provider
    }

    private func posts(_ client: AnthropicMockHTTPClient) -> [URLRequest] {
        client.requests.filter { $0.httpMethod == "POST" }
    }

    private func grantIDs(_ client: AnthropicMockHTTPClient) throws -> [String?] {
        try posts(client).map { try body($0)["grant_id"] as? String }
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func spend(_ provider: AnthropicProvider, _ choice: ResetKind.Key?, attempt: UUID = UUID()) async throws -> ResetOutcome {
        try await provider.useReset(account: account, credential: credential, attemptID: attempt, choice: choice)
    }

    // MARK: The chosen kind

    func testEachChoiceSendsAGrantOfThatKind() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await readProvider(client, body: try kindsBody())
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

        let refill = try await spend(provider, .modelRefill)
        let full = try await spend(provider, .full)
        XCTAssertEqual([refill, full], [.reset, .reset])
        XCTAssertEqual(try grantIDs(client), [markerGrant, "grant-full-soon"], "within a kind, the grant that ends soonest")
        for post in posts(client) {
            XCTAssertEqual(Set(try body(post).keys), ["program", "grant_id", "request_id"], "the kind never goes on the wire")
            XCTAssertEqual(post.url, resetURL)
        }
    }

    /// A blocked kind sends nothing, even while another kind is spendable.
    func testABlockedKindIsNeverSentOrReplaced() async throws {
        let client = AnthropicMockHTTPClient()
        let body = try kindsBody { grants in grants[2]["percent_used"] = ["model_a": 0] }
        let provider = try await readProvider(client, body: body)

        let outcome = try await spend(provider, .modelRefill)
        XCTAssertEqual(outcome, .blocked(.nothingToGiveBack))
        XCTAssertTrue(posts(client).isEmpty)
    }

    func testAKindTheReadingDoesNotHoldIsNotAvailable() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await readProvider(client, body: try kindsBody())
        let outcome = try await spend(provider, .session)
        XCTAssertEqual(outcome, .notAvailable)
        XCTAssertTrue(posts(client).isEmpty)
    }

    /// A spend with no choice never spends on an account with kinds.
    func testNoChoiceOnAnAccountWithKindsSendsNothing() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await readProvider(client, body: try kindsBody())
        let outcome = try await spend(provider, nil)
        XCTAssertEqual(outcome, .needsFreshReading)
        XCTAssertEqual(client.requests.count, 2, "no usage read, no POST")
    }

    /// Expiry is judged by the clock at the click, not at the read.
    func testTheClockAtTheClickDecides() async throws {
        let clock = MovableNow(start)
        let client = AnthropicMockHTTPClient()
        let provider = try await readProvider(client, body: try kindsBody(), clock: clock)
        clock.advance(by: 13 * 86_400)
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

        _ = try await spend(provider, .full)
        XCTAssertEqual(try grantIDs(client), ["grant-full-late"], "the sooner grant ended on 25 July")
    }

    // MARK: Resends

    /// A resend reuses the request id and the grant first sent, whether a
    /// later read drops that grant, pauses it, or would pick another.
    func testAResendKeepsItsGrantWhateverTheNextReadingSays() async throws {
        let rereads: [(String, (inout [[String: Any]]) -> Void)] = [
            ("dropped", { grants in grants.remove(at: 1) }),
            ("paused", { grants in grants[1]["paused"] = true }),
            ("another picked", { grants in grants[0]["ends_at"] = "2026-07-20T00:00:00Z" }),
        ]
        for (name, edit) in rereads {
            let client = AnthropicMockHTTPClient()
            let provider = try await readProvider(client, body: try kindsBody())
            client.enqueue(status: 503)
            client.enqueue(status: 200, body: try kindsBody(edit))
            client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

            do {
                _ = try await spend(provider, .full, attempt: markerAttempt)
                XCTFail("expected a 503")
            } catch UsageError.httpStatus(503) {}
            _ = try await provider.fetchStatus(account: account, credential: credential)
            let resent = try await spend(provider, .full, attempt: markerAttempt)
            XCTAssertEqual(resent, .reset, name)

            XCTAssertEqual(try grantIDs(client), ["grant-full-soon", "grant-full-soon"], name)
            let ids = try posts(client).map { try body($0)["request_id"] as? String }
            XCTAssertEqual(ids, [markerAttempt.uuidString.lowercased(), markerAttempt.uuidString.lowercased()], name)
        }
    }

    /// The request id is an idempotency key only together with its grant, so
    /// the same attempt for another kind sends nothing.
    func testAResendForAnotherKindSendsNothing() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await readProvider(client, body: try kindsBody())
        client.enqueue(status: 503)
        _ = try? await spend(provider, .full, attempt: markerAttempt)

        do {
            _ = try await spend(provider, .modelRefill, attempt: markerAttempt)
            XCTFail("expected a refusal")
        } catch UsageError.invalidResponse {}
        XCTAssertEqual(posts(client).count, 1)
    }

    /// The result table maps the same for a model refill as for a full reset.
    func testResultsMapTheSameForEveryKind() async throws {
        let table: [(String, ResetOutcome)] = [
            (#"{"result":"reset"}"#, .reset),
            (#"{"result":"already_used"}"#, .reset),
            (#"{"result":"not_limited"}"#, .nothingToReset),
            (#"{"result":"unavailable"}"#, .unexpected),
        ]
        for kind in [ResetKind.Key.full, .modelRefill] {
            for (answer, expected) in table {
                let client = AnthropicMockHTTPClient()
                let provider = try await readProvider(client, body: try kindsBody())
                client.enqueue(status: 200, body: Data(answer.utf8))
                let outcome = try await spend(provider, kind)
                let reference = AnthropicResetParser.outcome(Data(answer.utf8), now: start)
                XCTAssertEqual(outcome, reference, "\(kind) \(answer)")
                XCTAssertEqual(outcome, expected, "\(kind) \(answer)")
            }
        }
    }

    // MARK: Diagnostics

    private func diagnosticsHome() -> (Diagnostics, AppPaths, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThrottleSpendDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(applicationSupportDirectory: directory)
        return (Diagnostics(paths: paths), paths, directory)
    }

    private func lines(_ paths: AppPaths) -> [String] {
        let text = (try? String(contentsOf: paths.diagnosticsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// A failed reset leaves no organization, grant or request id on disk:
    /// the URL's id is replaced and the body echo is scrubbed, for a 500 and
    /// for a 429.
    func testAFailedResetLineKeepsNoIDs() async throws {
        let echo = Data(#"{"error":"boom","org":"\#(markerOrganization)","grant":"\#(markerGrant)","request":"\#(markerAttempt.uuidString.lowercased())","upper":"\#(markerAttempt.uuidString)"}"#.utf8)
        for (status, headers) in [(500, [String: String]()), (429, ["Retry-After": "30"])] {
            let (diagnostics, paths, directory) = diagnosticsHome()
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = AnthropicMockHTTPClient()
            let provider = try await readProvider(client, body: try kindsBody(), diagnostics: diagnostics)
            client.enqueue(status: status, body: echo, headers: headers)
            _ = try? await spend(provider, .modelRefill, attempt: markerAttempt)

            let written = lines(paths).filter { $0.contains(#""kind":"reset""#) }
            XCTAssertEqual(written.count, 1, "HTTP \(status)")
            let text = lines(paths).joined(separator: "\n")
            for marker in [markerOrganization, markerGrant, markerAttempt.uuidString.lowercased(), markerAttempt.uuidString] {
                XCTAssertFalse(text.lowercased().contains(marker.lowercased()), "\(marker) on disk after HTTP \(status)")
            }
            XCTAssertTrue(text.contains(AnthropicProvider.hiddenOrganizationID), "the URL keeps its shape")
        }
    }

    /// An eligible block that yields no count says why, once per account
    /// per launch; an ineligible one names its reason, again only when the
    /// reason changes. Neither line reaches the status.
    func testTheResetBlockLinesAreWrittenOncePerReason() async throws {
        let (diagnostics, paths, directory) = diagnosticsHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AnthropicMockHTTPClient()
        func withBlock(_ block: String) throws -> Data {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-limits")) as? [String: Any])
            root[AnthropicResetParser.blockKey] = try JSONSerialization.jsonObject(with: Data(block.utf8))
            return try JSONSerialization.data(withJSONObject: root)
        }
        let broken = try withBlock(#"{"eligible":true,"grants":[{"id":"Bad Id","resets_left":1}]}"#)
        func ineligible(_ reason: String) throws -> Data {
            try withBlock(#"{"eligible":false,"ineligible_reason":"\#(reason)"}"#)
        }
        let provider = try await readProvider(client, body: broken, diagnostics: diagnostics)
        for body in [broken, try ineligible("tier"), try ineligible("tier"), try ineligible("seat")] {
            client.enqueue(status: 200, body: body)
            let status = try? await provider.fetchStatus(account: account, credential: credential)
            if let status {
                let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
                XCTAssertFalse(encoded.contains("tier") || encoded.contains("seat") || encoded.contains("Bad Id"), encoded)
            }
        }

        let messages = lines(paths).compactMap { line -> String? in
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return entry["message"] as? String
        }
        XCTAssertEqual(messages.filter { $0.hasPrefix("Reset block yields no count") }, ["Reset block yields no count: \(AnthropicResetParser.Grant.Rule.id.rawValue)"])
        XCTAssertEqual(messages.filter { $0.hasPrefix("Resets not offered") }, ["Resets not offered: tier", "Resets not offered: seat"])
    }
}
