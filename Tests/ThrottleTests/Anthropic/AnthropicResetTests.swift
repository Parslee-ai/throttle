import XCTest
@testable import Throttle

/// The Claude adapter's banked-reset path: the count on the usage read, and
/// `useReset`, the one call that spends anything.
final class AnthropicResetTests: XCTestCase {
    private let fixedNow = Date.iso("2026-07-13T12:00:00Z")
    private let orgUUID = "00000000-0000-0000-0000-000000000000"
    private let attemptID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000ABCD")!

    private var account: Account {
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, provider: .anthropic, email: "user@example.com", sortIndex: 0)
    }

    private var credential: AccountCredential {
        AccountCredential(
            accessToken: AnthropicSampleSecret.accessToken,
            refreshToken: AnthropicSampleSecret.refreshToken,
            expiresAt: fixedNow.addingTimeInterval(3600),
            accountID: "acct_test",
            scopes: ["user:profile", "user:inference"]
        )
    }

    private var resetURL: URL {
        URL(string: "https://api.anthropic.com/api/organizations/\(orgUUID)/reset_rate_limits")!
    }

    private func twoGrants() throws -> Data { try AnthropicFixtures.data("anthropic-resets-two-grants") }
    private func profileBody() throws -> Data { try AnthropicFixtures.data("anthropic-profile") }

    private func makeProvider(_ client: AnthropicMockHTTPClient, now: (@Sendable () -> Date)? = nil, diagnostics: Diagnostics? = nil) -> AnthropicProvider {
        let fixed = fixedNow
        return AnthropicProvider(client: client, now: now ?? { fixed }, diagnostics: diagnostics)
    }

    /// A provider that has polled once: it knows the grant and, from the
    /// plan read, the organization. The client has answered two requests.
    private func primedProvider(_ client: AnthropicMockHTTPClient, diagnostics: Diagnostics? = nil) async throws -> AnthropicProvider {
        client.enqueue(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: try profileBody())
        let provider = makeProvider(client, diagnostics: diagnostics)
        _ = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(client.requests.count, 2)
        return provider
    }

    private func posts(_ client: AnthropicMockHTTPClient) -> [URLRequest] {
        client.requests.filter { $0.httpMethod == "POST" }
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: Reading the count

    func testUsageQueryItemsAreExactAndTheUserAgentIsThrottles() async throws {
        let client = AnthropicMockHTTPClient()
        _ = try await primedProvider(client)
        let usage = try XCTUnwrap(client.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(usage.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.anthropic.com")
        XCTAssertEqual(components.path, "/api/oauth/usage")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "at_wall", value: "1"),
            URLQueryItem(name: "skip_spend", value: "1"),
            URLQueryItem(name: "cedar_ember", value: "1"),
        ])
        let agent = try XCTUnwrap(usage.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent.hasPrefix("throttle/"), agent)
        XCTAssertFalse(agent.lowercased().contains("claude"), "never Claude Code's user agent")
        XCTAssertNil(usage.value(forHTTPHeaderField: "x-app"))
    }

    func testCountRidesOnTheOneUsageRequest() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: try twoGrants())
        let provider = makeProvider(client)

        let first = try await provider.fetchStatus(account: account, credential: credential)
        let second = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(first.resetCreditsAvailable, 3)
        XCTAssertEqual(second.resetCreditsAvailable, 3)
        XCTAssertEqual(first.windows, try AnthropicUsageParser.parse(try AnthropicFixtures.data("anthropic-limits")))
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage, AnthropicEndpoints.profile, AnthropicEndpoints.usage])
        XCTAssertTrue(posts(client).isEmpty, "a poll never spends")
    }

    func testCountIsNilOrZeroByEligibility() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-resets-ineligible"))
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-resets-no-grants"))
        client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-limits"))
        let provider = makeProvider(client)

        let ineligible = try await provider.fetchStatus(account: account, credential: credential)
        let empty = try await provider.fetchStatus(account: account, credential: credential)
        let noBlock = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertNil(ineligible.resetCreditsAvailable)
        XCTAssertEqual(empty.resetCreditsAvailable, 0)
        XCTAssertNil(noBlock.resetCreditsAvailable)
        XCTAssertEqual(noBlock.planLabel, "max 20x")
    }

    /// No codename, grant id, or organization id reaches the status the UI
    /// and the status cache see.
    func testEncodedStatusCarriesNoCodenameOrIds() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: try profileBody())
        let status = try await makeProvider(client).fetchStatus(account: account, credential: credential)
        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        for forbidden in ["cedar", "juniper", "grant", orgUUID] {
            XCTAssertFalse(text.contains(forbidden), "\(forbidden) in \(text)")
        }
        XCTAssertTrue(text.contains("\"resetCreditsAvailable\":3"), text)
    }

    // MARK: The POST

    func testResetPostShape() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await primedProvider(client)
        client.enqueue(status: 200, body: Data(#"{"result":"reset","resets_left":2,"cleared":["five_hour"]}"#.utf8))

        let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .reset)

        XCTAssertEqual(client.requests.count, 3)
        let usage = client.requests[0]
        let post = try XCTUnwrap(posts(client).first)
        XCTAssertEqual(posts(client).count, 1)
        XCTAssertEqual(post.url, resetURL)
        XCTAssertEqual(post.url?.absoluteString, "https://api.anthropic.com/api/organizations/00000000-0000-0000-0000-000000000000/reset_rate_limits")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        for header in ["Authorization", "anthropic-beta", "anthropic-version", "Accept", "User-Agent"] {
            XCTAssertNotNil(post.value(forHTTPHeaderField: header), header)
            XCTAssertEqual(post.value(forHTTPHeaderField: header), usage.value(forHTTPHeaderField: header), header)
        }
        XCTAssertNil(post.value(forHTTPHeaderField: "x-app"))
        XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(post.httpShouldHandleCookies)

        let body = try jsonBody(post)
        XCTAssertEqual(Set(body.keys), ["program", "grant_id", "request_id"])
        XCTAssertEqual(body["program"] as? String, "cedar_ember")
        XCTAssertEqual(body["grant_id"] as? String, "grant_test_b", "no next_grant_id: the usable grant ending soonest")
        XCTAssertEqual(body["request_id"] as? String, "0a1b2c3d-0000-4000-8000-00000000abcd")
    }

    /// The plan read and the reset share one profile request per account.
    func testPlanReadThenResetSendsOneProfileRequest() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await primedProvider(client)
        client.enqueue(status: 200, body: Data(#"{"result":"not_limited"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"not_limited"}"#.utf8))

        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: UUID())
        XCTAssertEqual(client.requests.filter { $0.url == AnthropicEndpoints.profile }.count, 1)
        XCTAssertEqual(client.requests.filter { $0.url == AnthropicEndpoints.usage }.count, 1)
    }

    /// A reset before any poll this launch learns the grant with one usage
    /// read and the organization with one profile read; the next poll then
    /// reads no profile.
    func testResetBeforeAnyPollLearnsGrantAndOrganizationOnce() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))
        client.enqueue(status: 200, body: try twoGrants())
        let provider = makeProvider(client)

        let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .reset)
        let status = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(status.planLabel, "max 20x")
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL, AnthropicEndpoints.usage])
    }

    func testRateLimitedUsageReadDuringResetSendsNothingMore() async throws {
        let client = AnthropicMockHTTPClient(status: 429, headers: ["Retry-After": "120"])
        do {
            _ = try await makeProvider(client).useReset(account: account, credential: credential, attemptID: attemptID)
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        }
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage])
    }

    /// The clean usage fixture with `cedar_ember` set to `block`.
    private func usageBody(block: String) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-limits")) as? [String: Any])
        root["cedar_ember"] = try JSONSerialization.jsonObject(with: Data(block.utf8))
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Grants are listed but none has a reset left: no credit, and no POST.
    func testGrantsWithNoResetsLeftAreNoCreditWithoutAPost() async throws {
        let body = try usageBody(block: #"{"eligible":true,"grants":[{"id":"grant_test_a","resets_left":0,"usable_now":true},{"id":"grant_test_b","resets_left":0}]}"#)
        let client = AnthropicMockHTTPClient(status: 200, body: body)
        let outcome = try await makeProvider(client).useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage])
    }

    /// A poll that found nothing to spend is remembered: the reset answers
    /// no credit without a usage read of its own.
    func testPolledNoGrantIsNoCreditWithoutAnyRequest() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-resets-no-grants"))
        client.enqueue(status: 200, body: try profileBody())
        let provider = makeProvider(client)
        _ = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(client.requests.count, 2)

        let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(client.requests.count, 2, "no usage read, no profile read, no POST")
    }

    /// A counted grant that is not usable now is still sent, so the button
    /// never shows a count it cannot act on; the provider answers for itself.
    func testNonUsableGrantIsSentAndTheProviderAnswers() async throws {
        let body = try usageBody(block: #"{"eligible":true,"grants":[{"id":"grant_test_idle","resets_left":1,"usable_now":false,"ends_at":"2026-08-01T00:00:00Z"}]}"#)
        let client = AnthropicMockHTTPClient(status: 200, body: body)
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: Data(#"{"result":"not_limited","reason":"not_limited"}"#.utf8))
        let provider = makeProvider(client)

        let status = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(status.resetCreditsAvailable, 1)
        let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertEqual(try jsonBody(try XCTUnwrap(posts(client).first))["grant_id"] as? String, "grant_test_idle")
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL])
    }

    func testNoUsableGrantIsNoCreditWithoutAPost() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-resets-no-grants"))
        let outcome = try await makeProvider(client).useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage])
    }

    /// A grant whose id fails the rule is never selected, so no POST carries it.
    func testInvalidGrantIDSendsNoPost() async throws {
        let shapes = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-resets-malformed-blocks")) as? [String: Any])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-limits")) as? [String: Any])
        root["cedar_ember"] = shapes["grant_id_path"]
        let client = AnthropicMockHTTPClient(status: 200, body: try JSONSerialization.data(withJSONObject: root))
        let outcome = try await makeProvider(client).useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertTrue(posts(client).isEmpty)
    }

    func testResetRequestRefusesMalformedIds() {
        let provider = makeProvider(AnthropicMockHTTPClient())
        let cases: [(String, String, String)] = [
            (orgUUID, "Grant_Upper", "request-1"),
            (orgUUID, "../grant", "request-1"),
            (orgUUID, String(repeating: "g", count: 41), "request-1"),
            (orgUUID, "grant_ok", "request id"),
            (orgUUID, "grant_ok", String(repeating: "r", count: 65)),
            ("../org", "grant_ok", "request-1"),
        ]
        for (org, grant, request) in cases {
            XCTAssertThrowsError(try provider.resetRequest(organizationUUID: org, grantID: grant, requestID: request, accessToken: "t")) { error in
                guard case UsageError.invalidResponse = error else { return XCTFail("got \(error)") }
            }
        }
        XCTAssertNoThrow(try provider.resetRequest(organizationUUID: orgUUID, grantID: "grant_ok", requestID: attemptID.uuidString.lowercased(), accessToken: "t"))
    }

    func testConsoleTokenIsNeedsLoginWithoutARequest() async {
        let client = AnthropicMockHTTPClient()
        do {
            _ = try await makeProvider(client).useReset(account: account, credential: AccountCredential(accessToken: "t", scopes: ["user:profile"]), attemptID: attemptID)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
            XCTAssertTrue(client.requests.isEmpty)
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: Organization id

    /// A profile on hold from the plan read is honored: no profile request,
    /// no POST, and the wait reported is what is left of the hold.
    func testHeldProfileSendsNoPost() async throws {
        let clock = MovableNow(fixedNow)
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(status: 429, headers: ["Retry-After": "600"])
        let provider = makeProvider(client, now: { clock.now })
        _ = try await provider.fetchStatus(account: account, credential: credential)

        clock.advance(by: 100)
        do {
            _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(try XCTUnwrap(retryAfter), 500, accuracy: 0.5)
        }
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage, AnthropicEndpoints.profile])
    }

    /// A profile refused during the reset holds like the plan read's, and the
    /// hold stops the next attempt before any request.
    func testRefusedProfileDuringResetHoldsAndSendsNoPost() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(error: UsageError.transport(URLError(.timedOut)))
        client.enqueue(status: 503)
        let provider = makeProvider(client)
        _ = try await provider.fetchStatus(account: account, credential: credential)

        for _ in 0..<2 {
            do {
                _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
                XCTFail("expected rateLimited")
            } catch UsageError.rateLimited(let retryAfter) {
                XCTAssertEqual(retryAfter, AnthropicProvider.profileRefusalHold)
            }
        }
        XCTAssertEqual(client.requests.map(\.url), [AnthropicEndpoints.usage, AnthropicEndpoints.profile, AnthropicEndpoints.profile])
        XCTAssertTrue(posts(client).isEmpty)
    }

    func testProfileWithoutOrganizationIsNotAvailableWithoutAPost() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: Data(#"{"account":{"email":"user@example.com"},"organization":{"organization_type":"claude_pro"}}"#.utf8))
        let outcome = try await makeProvider(client).useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(outcome, .notAvailable)
        XCTAssertTrue(posts(client).isEmpty)
    }

    /// A new sign-in forgets the organization and the grant, so the reset
    /// goes to the new sign-in's organization.
    func testSignInForgetsTheOrganization() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await primedProvider(client)
        await provider.accountDidSignIn(account.id)
        client.enqueue(status: 200, body: try twoGrants())
        client.enqueue(status: 200, body: Data(#"{"organization":{"uuid":"\#(otherOrg)","organization_type":"claude_pro"}}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(posts(client).first?.url?.absoluteString, "https://api.anthropic.com/api/organizations/\(otherOrg)/reset_rate_limits")
        XCTAssertEqual(client.requests.filter { $0.url == AnthropicEndpoints.profile }.count, 2)
    }

    // MARK: Idempotency

    func testRetriesReuseTheRequestIDAndANewClickGetsANewOne() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await primedProvider(client)
        for _ in 0..<3 { client.enqueue(status: 200, body: Data(#"{"result":"already_used"}"#.utf8)) }

        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: UUID())
        let ids = try posts(client).map { try jsonBody($0)["request_id"] as? String }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotEqual(ids[1], ids[2])
    }

    /// Grant A named next with one reset left, and grant B with two.
    private func aSelectedBody() throws -> Data {
        try usageBody(block: #"{"eligible":true,"grants":[{"id":"grant_test_a","resets_left":1,"usable_now":true,"ends_at":"2026-08-01T00:00:00Z"},{"id":"grant_test_b","resets_left":2,"usable_now":true,"ends_at":"2026-07-20T00:00:00Z"}],"next_grant_id":"grant_test_a"}"#)
    }

    /// Grant A spent, so a read selects grant B.
    private func bSelectedBody() throws -> Data {
        try usageBody(block: #"{"eligible":true,"grants":[{"id":"grant_test_a","resets_left":0,"usable_now":false,"ends_at":"2026-08-01T00:00:00Z"},{"id":"grant_test_b","resets_left":2,"usable_now":true,"ends_at":"2026-07-20T00:00:00Z"}],"next_grant_id":null}"#)
    }

    private func grantIDs(_ client: AnthropicMockHTTPClient) throws -> [String?] {
        try posts(client).map { try jsonBody($0)["grant_id"] as? String }
    }

    /// An attempt whose answer left it unconfirmed is resent to the grant it
    /// first named, even after a read selects another grant, so one request
    /// id can never spend two grants. A new attempt selects afresh.
    func testResendOfAnAttemptKeepsItsGrantAfterAReadSelectsAnother() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try aSelectedBody())
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: Data(#"{"result":"unavailable"}"#.utf8))
        client.enqueue(status: 200, body: try bSelectedBody())
        client.enqueue(status: 200, body: Data(#"{"result":"already_used"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))
        let provider = makeProvider(client)
        _ = try await provider.fetchStatus(account: account, credential: credential)

        let first = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(first, .unexpected)
        let reread = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(reread.resetCreditsAvailable, 2)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: UUID())

        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_a", "grant_test_b"])
        let ids = try posts(client).map { try jsonBody($0)["request_id"] as? String }
        XCTAssertEqual(ids[0], "0a1b2c3d-0000-4000-8000-00000000abcd")
        XCTAssertEqual(ids[1], ids[0])
        XCTAssertNotEqual(ids[2], ids[0])
        XCTAssertEqual(client.requests.map(\.url), [
            AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL,
            AnthropicEndpoints.usage, resetURL, resetURL,
        ])
    }

    private let otherOrg = "11111111-1111-1111-1111-111111111111"

    private var otherResetURL: URL {
        URL(string: "https://api.anthropic.com/api/organizations/\(otherOrg)/reset_rate_limits")!
    }

    private func otherOrgProfile() -> Data {
        Data(#"{"organization":{"uuid":"\#(otherOrg)","organization_type":"claude_pro"}}"#.utf8)
    }

    /// Sends one attempt that ends in a 503, so the provider may have spent
    /// grant A without saying so. The client has answered three requests.
    private func attemptEndingIn503(_ client: AnthropicMockHTTPClient) async throws -> AnthropicProvider {
        client.enqueue(status: 200, body: try aSelectedBody())
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 503)
        let provider = makeProvider(client)
        _ = try await provider.fetchStatus(account: account, credential: credential)
        do {
            let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
            XCTFail("expected a 503, got \(outcome)")
        } catch UsageError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        return provider
    }

    /// The reset gets a 503 after the provider may have spent grant A, the
    /// account signs in again to the same organization, and a fresh read
    /// selects grant B. The resend of the same attempt still goes to A, so
    /// one request id can never spend B as well. A new attempt selects B.
    func testSignInToTheSameOrganizationKeepsTheAttemptsGrantPin() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await attemptEndingIn503(client)

        await provider.accountDidSignIn(account.id)
        client.enqueue(status: 200, body: try bSelectedBody())
        client.enqueue(status: 200, body: try profileBody())
        let reread = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertEqual(reread.resetCreditsAvailable, 2)
        client.enqueue(status: 200, body: Data(#"{"result":"already_used"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

        let resent = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(resent, .reset)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: UUID())

        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_a", "grant_test_b"])
        let ids = try posts(client).map { try jsonBody($0)["request_id"] as? String }
        XCTAssertEqual(ids[1], ids[0])
        XCTAssertNotEqual(ids[2], ids[0])
        XCTAssertEqual(client.requests.map(\.url), [
            AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL,
            AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL, resetURL,
        ])
    }

    /// The same scenario with no poll between the sign-in and the resend:
    /// the resend reads the profile to learn the organization, finds it
    /// unchanged, and goes to A with no usage read.
    func testResendRightAfterASignInReadsTheOrganizationAndKeepsThePin() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await attemptEndingIn503(client)

        await provider.accountDidSignIn(account.id)
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: Data(#"{"result":"already_used"}"#.utf8))
        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)

        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_a"])
        XCTAssertEqual(client.requests.map(\.url), [
            AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL,
            AnthropicEndpoints.profile, resetURL,
        ])
    }

    /// A sign-in to another organization drops the pin once the resend
    /// learns the new organization: the attempt is a fresh one there, so it
    /// selects from a new read and goes to the new organization. Its pin is
    /// then the new organization's, and a further resend keeps it.
    func testSignInToAnotherOrganizationDropsThePin() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await attemptEndingIn503(client)

        await provider.accountDidSignIn(account.id)
        client.enqueue(status: 200, body: otherOrgProfile())
        client.enqueue(status: 200, body: try bSelectedBody())
        client.enqueue(status: 503)
        client.enqueue(status: 200, body: try aSelectedBody())
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))

        do {
            _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
            XCTFail("expected a 503")
        } catch UsageError.httpStatus(503) {}
        _ = try await provider.fetchStatus(account: account, credential: credential)
        let resent = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(resent, .reset)

        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_b", "grant_test_b"])
        XCTAssertEqual(client.requests.map(\.url), [
            AnthropicEndpoints.usage, AnthropicEndpoints.profile, resetURL,
            AnthropicEndpoints.profile, AnthropicEndpoints.usage, otherResetURL,
            AnthropicEndpoints.usage, otherResetURL,
        ])
    }

    /// One pin per account: a new attempt replaces the old one's, so a late
    /// resend of the old attempt selects afresh.
    func testOnlyTheLatestAttemptIsPinned() async throws {
        let client = AnthropicMockHTTPClient()
        let provider = try await attemptEndingIn503(client)
        let second = UUID()
        client.enqueue(status: 200, body: try bSelectedBody())
        client.enqueue(status: 200, body: Data(#"{"result":"unavailable"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"unavailable"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"result":"unavailable"}"#.utf8))

        _ = try await provider.fetchStatus(account: account, credential: credential)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: second)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
        _ = try await provider.useReset(account: account, credential: credential, attemptID: second)

        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_b", "grant_test_b", "grant_test_b"])
    }

    /// The pin lives in memory only: a relaunched adapter does not know it,
    /// and nothing about it lands in the app's defaults.
    func testThePinIsNeverPersisted() async throws {
        let client = AnthropicMockHTTPClient()
        _ = try await attemptEndingIn503(client)

        let relaunched = makeProvider(client)
        client.enqueue(status: 200, body: try bSelectedBody())
        client.enqueue(status: 200, body: try profileBody())
        client.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))
        _ = try await relaunched.useReset(account: account, credential: credential, attemptID: attemptID)
        XCTAssertEqual(try grantIDs(client), ["grant_test_a", "grant_test_b"])

        let defaults = String(describing: UserDefaults.standard.dictionaryRepresentation())
        for secretish in ["grant_test_a", attemptID.uuidString.lowercased(), attemptID.uuidString] {
            XCTAssertFalse(defaults.contains(secretish), "\(secretish) is in UserDefaults")
        }
    }

    // MARK: Answers

    func testEachResultMapsThroughTheAdapter() async throws {
        let table: [(String, ResetOutcome)] = [
            (#"{"result":"reset","resets_left":0}"#, .reset),
            (#"{"result":"already_used"}"#, .reset),
            (#"{"result":"not_limited","reason":"not_limited"}"#, .nothingToReset),
            (#"{"result":"cooldown","cooldown_until":"2026-07-13T12:10:00Z"}"#, .cooldown(until: Date.iso("2026-07-13T12:10:00Z"))),
            (#"{"result":"cooldown","cooldown_until":"2026-07-13T11:10:00Z"}"#, .cooldown(until: nil)),
            (#"{"result":"ineligible","reason":"tier"}"#, .notAvailable),
            (#"{"result":"unavailable"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"tier"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"not_next_grant"}"#, .notAvailable),
            (#"{"result":"ineligible","reason":"unknown_grant"}"#, .notAvailable),
            (#"{"result":"not_next_grant"}"#, .notAvailable),
            (#"{"result":"unknown_grant"}"#, .notAvailable),
            (#"{"result":"ineligible","reason":"no_grant"}"#, .noCredit),
            (#"{"result":"grant_id_required"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"grant_id_required"}"#, .unexpected),
            (#"{"result":"stamp_indeterminate"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"stamp_indeterminate"}"#, .unexpected),
            (#"{"result":"reset_unconfirmed"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"reset_unconfirmed"}"#, .unexpected),
            (#"{"result":"a_new_answer"}"#, .unexpected),
            ("not json", .unexpected),
        ]
        for (body, expected) in table {
            let client = AnthropicMockHTTPClient()
            let provider = try await primedProvider(client)
            client.enqueue(status: 200, body: Data(body.utf8))
            let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
            XCTAssertEqual(outcome, expected, body)
        }
    }

    private func resetError(status: Int, body: Data = Data(), headers: [String: String] = [:], diagnostics: Diagnostics? = nil) async throws -> (Error, AnthropicMockHTTPClient) {
        let client = AnthropicMockHTTPClient()
        let provider = try await primedProvider(client, diagnostics: diagnostics)
        client.enqueue(status: status, body: body, headers: headers)
        do {
            let outcome = try await provider.useReset(account: account, credential: credential, attemptID: attemptID)
            XCTFail("expected an error, got \(outcome)")
            return (UsageError.invalidResponse("none"), client)
        } catch {
            XCTAssertEqual(client.requests.count, 3, "one POST, no refresh and no retry")
            return (error, client)
        }
    }

    func testUnauthorizedIsNeedsLoginWithoutARefresh() async throws {
        let (error, client) = try await resetError(status: 401)
        guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
        XCTAssertFalse(client.requests.contains { $0.url == AnthropicEndpoints.token || $0.url == AnthropicEndpoints.tokenFallback })
    }

    func testForbiddenWithPermissionBodyIsForbidden() async throws {
        let body = Data(#"{"type":"error","error":{"type":"permission_error","message":"Not allowed for Bearer \#(FakeToken.anthropicSecret)"}}"#.utf8)
        let (error, _) = try await resetError(status: 403, body: body)
        guard case UsageError.forbidden(let reason) = error else { return XCTFail("got \(error)") }
        XCTAssertFalse(reason.contains("secret-value"), reason)
    }

    func testOtherForbiddenIsNeedsLogin() async throws {
        let (error, _) = try await resetError(status: 403, body: Data("{}".utf8))
        guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
    }

    func testRateLimitedCarriesRetryAfter() async throws {
        let (error, _) = try await resetError(status: 429, headers: ["Retry-After": "90"])
        guard case UsageError.rateLimited(let retryAfter) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(retryAfter, 90)
    }

    func testRedirectIsRedirect() async throws {
        let (error, _) = try await resetError(status: 302, headers: ["Location": "https://claude.ai/login"])
        guard case UsageError.redirect = error else { return XCTFail("got \(error)") }
    }

    func testServerErrorIsHTTPStatusAndLeaksNoToken() async throws {
        let body = Data(#"{"error":"boom","echo":"Authorization: Bearer sk-ant-xyz"}"#.utf8)
        let (error, _) = try await resetError(status: 500, body: body)
        guard case UsageError.httpStatus(let code) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(code, 500)
        for rendering in [String(describing: error), String(reflecting: error), error.localizedDescription] {
            XCTAssertFalse(rendering.contains("sk-ant"), rendering)
            XCTAssertFalse(rendering.contains(AnthropicSampleSecret.accessToken), rendering)
        }
    }

    func testNon200PostWritesOneRedactedResetDiagnosticsLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThrottleResetDiagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let diagnostics = Diagnostics(paths: paths)
        let echoed = Data(#"{"error":"boom","echo":"Bearer \#(AnthropicSampleSecret.accessToken)"}"#.utf8)
        _ = try await resetError(status: 500, body: echoed, diagnostics: diagnostics)

        let text = try String(contentsOf: paths.diagnosticsFile, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, text)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(entry["kind"] as? String, "reset")
        XCTAssertEqual(entry["status"] as? Int, 500)
        XCTAssertEqual(entry["url"] as? String, resetURL.absoluteString)
        let headers = try XCTUnwrap(entry["requestHeaders"] as? [String: String])
        XCTAssertFalse(headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame })
        XCTAssertFalse(text.contains(AnthropicSampleSecret.accessToken))
        XCTAssertFalse(text.contains("Bearer "))
    }
}
