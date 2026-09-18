import XCTest
@testable import Throttle

/// The on-disk diagnostics log: one JSON line per provider failure, the bearer
/// header removed rather than masked, the body redacted, the file 0600 and
/// capped.
final class DiagnosticsTests: XCTestCase {
    private var directory: URL!
    private var paths: AppPaths!
    private var diagnostics: Diagnostics!
    private let fixedNow = Date.iso("2026-09-17T16:00:00Z")

    private var account: Account {
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!, provider: .anthropic, email: "user@example.com", sortIndex: 0)
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

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupportDirectory: directory)
        diagnostics = Diagnostics(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines() throws -> [[String: Any]] {
        let text = try String(contentsOf: paths.diagnosticsFile, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "line is a JSON object: \(line)")
        }
    }

    private func fileText() throws -> String {
        try String(contentsOf: paths.diagnosticsFile, encoding: .utf8)
    }

    // MARK: Anthropic 429

    func testAnthropic429WritesOneRedactedLine() async throws {
        let echoedBody = #"{"error":"rate limited","echo":"Bearer \#(AnthropicSampleSecret.accessToken)"}"#
        let client = AnthropicMockHTTPClient(status: 429, body: Data(echoedBody.utf8), headers: ["Retry-After": "3600"])
        let provider = AnthropicProvider(client: client, now: { [fixedNow] in fixedNow }, diagnostics: diagnostics)

        do {
            _ = try await provider.fetchStatus(account: account, credential: credential)
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 3600)
        }

        let entries = try lines()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["kind"] as? String, "usage")
        XCTAssertEqual(entry["provider"] as? String, "anthropic")
        XCTAssertEqual(entry["accountID"] as? String, account.id.uuidString)
        XCTAssertEqual(entry["status"] as? Int, 429)
        XCTAssertEqual(entry["retryAfterSeconds"] as? Int, 3600)
        XCTAssertEqual(entry["ts"] as? String, "2026-09-17T16:00:00Z")
        XCTAssertEqual(entry["url"] as? String, AnthropicEndpoints.usage.absoluteString)

        let headers = try XCTUnwrap(entry["requestHeaders"] as? [String: String])
        XCTAssertFalse(headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }, "Authorization is removed, not masked")
        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertNotNil(headers["User-Agent"])

        let body = try XCTUnwrap(entry["bodyPrefix"] as? String)
        XCTAssertTrue(body.contains("[redacted]"))
        XCTAssertFalse(body.contains(AnthropicSampleSecret.accessToken))

        let text = try fileText()
        XCTAssertFalse(text.contains(AnthropicSampleSecret.accessToken), "the file never holds the bearer token")
        XCTAssertFalse(text.contains("Bearer "), "no bearer prefix survives, even redacted in place")
    }

    func testNothingIsWrittenOn200() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-limits"))
        let provider = AnthropicProvider(client: client, now: { [fixedNow] in fixedNow }, diagnostics: diagnostics)
        _ = try await provider.fetchStatus(account: account, credential: credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.diagnosticsFile.path))
    }

    func testAnthropicRefreshFailureIsRecordedWithoutTheRefreshToken() async throws {
        let client = AnthropicMockHTTPClient(status: 500, body: Data(#"{"error":"upstream"}"#.utf8))
        let provider = AnthropicProvider(client: client, now: { [fixedNow] in fixedNow }, diagnostics: diagnostics)
        await XCTAssertThrowsErrorAsync(try await provider.refresh(credential: credential))

        let entry = try XCTUnwrap(lines().first)
        XCTAssertEqual(entry["kind"] as? String, "refresh")
        XCTAssertEqual(entry["status"] as? Int, 500)
        XCTAssertNil(entry["accountID"])
        let text = try fileText()
        XCTAssertFalse(text.contains(AnthropicSampleSecret.refreshToken))
        XCTAssertFalse(text.contains(AnthropicSampleSecret.accessToken))
    }

    // MARK: OpenAI

    func testOpenAI429DropsTheBearerHeaderAndKeepsTheAccountHeader() async throws {
        let token = "eyJ" + String(repeating: "A", count: 40) + ".payload.sig"
        let client = OpenAIMockHTTPClient(responses: [
            .response(429, headers: ["Retry-After": "120"], body: #"{"detail":"slow down \#(token)"}"#),
        ])
        let provider = OpenAIProvider(client: client, now: { [fixedNow] in fixedNow }, diagnostics: diagnostics)
        let credential = AccountCredential(accessToken: token, refreshToken: "refresh-1", accountID: "acct-789")

        await XCTAssertThrowsErrorAsync(try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential))

        let entry = try XCTUnwrap(lines().first)
        XCTAssertEqual(entry["provider"] as? String, "openai")
        XCTAssertEqual(entry["status"] as? Int, 429)
        XCTAssertEqual(entry["retryAfterSeconds"] as? Int, 120)
        XCTAssertEqual(entry["accountID"] as? String, OpenAIFixtures.account.id.uuidString)
        let headers = try XCTUnwrap(entry["requestHeaders"] as? [String: String])
        XCTAssertNil(headers["Authorization"])
        XCTAssertEqual(headers["chatgpt-account-id"], "acct-789")
        XCTAssertFalse(try fileText().contains(token))
    }

    // MARK: File properties

    func testFileModeIs0600() async throws {
        await diagnostics.record(DiagnosticEvent(ts: fixedNow, provider: .anthropic, accountID: nil, kind: .scheduler, message: "hello"))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.diagnosticsFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEventsAppendInOrder() async throws {
        for index in 0..<3 {
            await diagnostics.record(DiagnosticEvent(ts: fixedNow, provider: .openai, accountID: nil, kind: .scheduler, message: "event \(index)"))
        }
        XCTAssertEqual(try lines().compactMap { $0["message"] as? String }, ["event 0", "event 1", "event 2"])
    }

    func testFileIsCutBackToTheLastQuarterMegabyteOnWholeLines() async throws {
        let filler = String(repeating: "x", count: 1_000)
        var count = 0
        while true {
            await diagnostics.record(DiagnosticEvent(ts: fixedNow, provider: .anthropic, accountID: nil, kind: .scheduler, message: "\(count) \(filler)"))
            count += 1
            let size = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: paths.diagnosticsFile.path)[.size] as? NSNumber)?.intValue)
            if size > Diagnostics.maxBytes { XCTFail("file exceeded the cap after a write: \(size)"); break }
            // One more line would push it past the cap: that write must shrink it.
            if size + 1_200 > Diagnostics.maxBytes { break }
            if count > 2_000 { XCTFail("cap never approached"); break }
        }
        await diagnostics.record(DiagnosticEvent(ts: fixedNow, provider: .anthropic, accountID: nil, kind: .scheduler, message: "\(count) \(filler)"))

        let size = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: paths.diagnosticsFile.path)[.size] as? NSNumber)?.intValue)
        XCTAssertLessThanOrEqual(size, Diagnostics.keepBytes)
        XCTAssertGreaterThan(size, Diagnostics.keepBytes - 2_000, "keeps close to the last 256 KB")

        let text = try fileText()
        XCTAssertTrue(text.hasPrefix("{"), "starts on a whole line")
        XCTAssertTrue(text.hasSuffix("}\n"))
        let entries = try lines()
        XCTAssertEqual(entries.last?["message"] as? String, "\(count) \(filler)", "the newest line survives")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.diagnosticsFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTailStartsAfterTheFirstNewline() {
        let data = Data("aaaa\nbbbb\ncccc\n".utf8)
        XCTAssertEqual(String(decoding: Diagnostics.tail(of: data, keeping: 7), as: UTF8.self), "cccc\n")
        XCTAssertEqual(Diagnostics.tail(of: data, keeping: 100), data)
    }

    func testStrippedHeadersDropsAuthorizationInAnyCase() {
        let stripped = DiagnosticEvent.strippedHeaders([
            "authorization": "Bearer abc",
            "AUTHORIZATION": "Bearer def",
            "Accept": "application/json",
            "X-Echo": "Bearer leaked",
        ])
        XCTAssertEqual(stripped, ["Accept": "application/json", "X-Echo": "[redacted]"])
    }
}

/// `XCTAssertThrowsError` cannot take an `await` in its autoclosure.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
