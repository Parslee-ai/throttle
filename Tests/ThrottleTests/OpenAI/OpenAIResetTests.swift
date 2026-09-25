import XCTest
@testable import Throttle

/// `OpenAIProvider.useReset`: the one spending call, posted to the consume
/// endpoint only when a person asks. Outcomes group B1, B3, B5.
final class OpenAIResetTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_787_000_000)
    private let attemptID = UUID(uuidString: "A1B2C3D4-E5F6-4789-8ABC-DEF012345678")!
    private var directory: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleOpenAIResetTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupportDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var credential: AccountCredential {
        AccountCredential(accessToken: "access-token-123", refreshToken: "refresh-token-456", accountID: "acct-789")
    }

    private func makeProvider(_ client: OpenAIMockHTTPClient, diagnostics: Diagnostics? = nil) -> OpenAIProvider {
        let now = fixedNow
        return OpenAIProvider(client: client, now: { now }, diagnostics: diagnostics)
    }

    private func reset(_ responses: [HTTPResponse], diagnostics: Diagnostics? = nil) async throws -> ResetOutcome {
        try await makeProvider(OpenAIMockHTTPClient(responses: responses), diagnostics: diagnostics)
            .useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody, "consume request has a body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - B1: the request

    func testRequestShape() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(#"{"code":"reset","windows_reset":1}"#)])
        let outcome = try await makeProvider(client)
            .useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(client.requests.count, 1, "exactly one request")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), OpenAIEndpoints.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex_cli_rs/0.145.0 (throttle)", "same identity as the usage read")
        XCTAssertEqual(client.maxBodyBytesSeen, [OpenAIProvider.maxResetBodyBytes])
    }

    func testBodyCarriesTheAttemptIDAndNoCreditID() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(#"{"code":"reset"}"#)])
        _ = try await makeProvider(client)
            .useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)

        let object = try bodyObject(try XCTUnwrap(client.requests.first))
        XCTAssertEqual(object["redeem_request_id"] as? String, attemptID.uuidString.lowercased())
        XCTAssertNil(object["credit_id"], "the provider picks the credit")
        XCTAssertEqual(Set(object.keys), ["redeem_request_id"])
    }

    func testAccountIDHeaderOmittedWhenCredentialHasNone() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(#"{"code":"reset"}"#)])
        _ = try await makeProvider(client)
            .useReset(account: OpenAIFixtures.account, credential: AccountCredential(accessToken: "tok"), attemptID: attemptID)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "chatgpt-account-id"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    /// The caller resends after a 401 and refresh with the same attempt id; the
    /// adapter must put that same id on the wire both times.
    func testSameAttemptIDGivesSameRedeemRequestIDAcrossCalls() async throws {
        let client = OpenAIMockHTTPClient(responses: [
            .json(401, #"{"detail":"Unauthorized"}"#),
            .json(#"{"code":"reset","windows_reset":1}"#),
        ])
        let provider = makeProvider(client)

        do {
            _ = try await provider.useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {}
        let rotated = AccountCredential(accessToken: "rotated-access", refreshToken: "rotated-refresh", accountID: "acct-789")
        let outcome = try await provider.useReset(account: OpenAIFixtures.account, credential: rotated, attemptID: attemptID)

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(client.requests.count, 2)
        let ids = try client.requests.map { try bodyObject($0)["redeem_request_id"] as? String }
        XCTAssertEqual(ids, [attemptID.uuidString.lowercased(), attemptID.uuidString.lowercased()])
        XCTAssertEqual(client.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-access")
    }

    func testDifferentAttemptsGetDifferentRedeemRequestIDs() {
        let first = OpenAIProvider.resetRequestBody(attemptID: UUID())
        let second = OpenAIProvider.resetRequestBody(attemptID: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(OpenAIProvider.resetRequestBody(attemptID: attemptID), OpenAIProvider.resetRequestBody(attemptID: attemptID))
    }

    // MARK: - B3: what each answer becomes

    func testCodeMapping() async throws {
        let cases: [(String, ResetOutcome)] = [
            ("reset", .reset),
            ("already_redeemed", .reset),
            ("nothing_to_reset", .nothingToReset),
            ("no_credit", .noCredit),
        ]
        for (code, expected) in cases {
            let outcome = try await reset([.json(#"{"code":"\#(code)","windows_reset":0}"#)])
            XCTAssertEqual(outcome, expected, code)
        }
    }

    func testCapturedFixtureWithCreditObjectIsReset() async throws {
        let body = String(decoding: try TestFixtures.data("wham-reset-consume"), as: UTF8.self)
        let outcome = try await reset([.json(body)])
        XCTAssertEqual(outcome, .reset, "the extra credit object is ignored")
    }

    func testUnknownCodeIsUnexpected() async throws {
        let outcome = try await reset([.json(#"{"code":"reset_pending_review","windows_reset":1}"#)])
        XCTAssertEqual(outcome, .unexpected)
    }

    func testUnparseable200IsUnexpected() async throws {
        for body in ["<html>ok</html>", "", "[]", #"{"windows_reset":1}"#, #"{"code":7}"#] {
            let outcome = try await reset([.json(body)])
            XCTAssertEqual(outcome, .unexpected, body)
        }
    }

    func testWindowsResetParsesAndDefaultsToZero() throws {
        XCTAssertEqual(OpenAIResetAnswer.parse(Data(#"{"code":"reset","windows_reset":2}"#.utf8)), OpenAIResetAnswer(code: "reset", windowsReset: 2))
        XCTAssertEqual(OpenAIResetAnswer.parse(Data(#"{"code":"reset"}"#.utf8))?.windowsReset, 0, "missing")
        XCTAssertEqual(OpenAIResetAnswer.parse(Data(#"{"code":"reset","windows_reset":null}"#.utf8))?.windowsReset, 0, "null")
        XCTAssertEqual(OpenAIResetAnswer.parse(Data(#"{"code":"reset","windows_reset":"two"}"#.utf8))?.windowsReset, 0, "not a number")
        XCTAssertEqual(OpenAIResetAnswer.parse(Data(#"{"code":"reset","windows_reset":true}"#.utf8))?.windowsReset, 0, "a bool is not a count")
        XCTAssertEqual(OpenAIResetAnswer.parse(try TestFixtures.data("wham-reset-consume"))?.windowsReset, 2)
        XCTAssertNil(OpenAIResetAnswer.parse(Data("not json".utf8)))
    }

    func test401IsNeedsLoginWithNoRetry() async {
        let client = OpenAIMockHTTPClient(responses: [.json(401, #"{"detail":"Unauthorized"}"#)])
        do {
            _ = try await makeProvider(client).useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
        } catch {
            XCTFail("expected needsLogin, got \(error)")
        }
        XCTAssertEqual(client.requests.count, 1, "no internal refresh or resend")
        XCTAssertEqual(client.requests.first?.url, OpenAIEndpoints.resetConsumeURL)
    }

    func test403WithPermissionErrorIsForbiddenAndRedacted() async {
        let body = #"{"error":{"type":"permission_error","message":"Not allowed for Bearer eyJabc.def.ghi"}}"#
        do {
            _ = try await reset([.json(403, body)])
            XCTFail("expected forbidden")
        } catch UsageError.forbidden(let reason) {
            XCTAssertEqual(reason, "Not allowed for [redacted]")
        } catch {
            XCTFail("expected forbidden, got \(error)")
        }
    }

    func test403WithoutPermissionErrorIsNeedsLogin() async {
        for response in [
            HTTPResponse.json(403, #"{"error":{"type":"invalid_request_error","message":"bad"}}"#),
            HTTPResponse.response(403, headers: ["Content-Type": "text/html"], body: "<html>denied</html>"),
        ] {
            do {
                _ = try await reset([response])
                XCTFail("expected needsLogin")
            } catch UsageError.needsLogin {
            } catch {
                XCTFail("expected needsLogin, got \(error)")
            }
        }
    }

    func test429CarriesRetryAfter() async {
        do {
            _ = try await reset([.response(429, headers: ["Retry-After": "90"], body: "slow down")])
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 90)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func test429WithoutHeaderHasNilRetryAfter() async {
        do {
            _ = try await reset([.response(429)])
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func test5xxAndOtherStatusesAreHTTPStatus() async {
        for status in [500, 503, 400, 404] {
            do {
                _ = try await reset([.response(status, body: "upstream")])
                XCTFail("expected httpStatus for \(status)")
            } catch UsageError.httpStatus(let code) {
                XCTAssertEqual(code, status)
            } catch {
                XCTFail("expected httpStatus for \(status), got \(error)")
            }
        }
    }

    func test3xxIsRedirect() async {
        for status in [301, 302, 307] {
            do {
                _ = try await reset([.response(status, headers: ["Location": "https://chatgpt.com/auth/login"])])
                XCTFail("expected redirect for \(status)")
            } catch UsageError.redirect {
            } catch {
                XCTFail("expected redirect for \(status), got \(error)")
            }
        }
    }

    /// The HTTP client drops an oversized body unread and throws `tooLarge`;
    /// the adapter passes that through rather than reading anything.
    func testOversizedBodyIsTooLarge() async {
        let client = OpenAIMockHTTPClient(results: [.failure(UsageError.tooLarge)])
        do {
            _ = try await makeProvider(client).useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)
            XCTFail("expected tooLarge")
        } catch UsageError.tooLarge {
        } catch {
            XCTFail("expected tooLarge, got \(error)")
        }
        XCTAssertEqual(client.maxBodyBytesSeen, [OpenAIProvider.maxResetBodyBytes])
    }

    func testTransportErrorsPropagate() async {
        struct Boom: Error {}
        let client = OpenAIMockHTTPClient(results: [.failure(UsageError.transport(Boom()))])
        do {
            _ = try await makeProvider(client).useReset(account: OpenAIFixtures.account, credential: credential, attemptID: attemptID)
            XCTFail("expected transport")
        } catch UsageError.transport {
        } catch {
            XCTFail("expected transport, got \(error)")
        }
    }

    // MARK: - B5: nothing leaks

    func testTokenEchoIn500NeverReachesAnErrorDescription() async throws {
        let jwt = "eyJabc.def.ghi"
        let key = "sk-abc123def456"
        let echo = #"{"error":"upstream","echo":"Authorization: Bearer \#(jwt)","key":"\#(key)"}"#
        let diagnostics = Diagnostics(paths: paths)
        do {
            _ = try await reset([.json(500, echo)], diagnostics: diagnostics)
            XCTFail("expected httpStatus")
        } catch {
            guard case UsageError.httpStatus(500) = error else {
                return XCTFail("expected httpStatus(500), got \(error)")
            }
            for text in [String(describing: error), error.localizedDescription, String(reflecting: error)] {
                XCTAssertFalse(text.contains("eyJabc"), text)
                XCTAssertFalse(text.contains("sk-abc123"), text)
                XCTAssertFalse(text.contains("access-token-123"), text)
            }
        }

        let file = try String(contentsOf: paths.diagnosticsFile, encoding: .utf8)
        XCTAssertFalse(file.contains("eyJabc"))
        XCTAssertFalse(file.contains("sk-abc123"))
        XCTAssertTrue(file.contains("[redacted]"), "the echoed token is replaced, not dropped silently")
    }

    func testNon200WritesOneResetDiagnosticsLineWithoutAuthorization() async throws {
        let diagnostics = Diagnostics(paths: paths)
        do {
            _ = try await reset([.response(503, headers: ["Retry-After": "30"], body: "unavailable")], diagnostics: diagnostics)
            XCTFail("expected httpStatus")
        } catch UsageError.httpStatus(503) {}

        let text = try String(contentsOf: paths.diagnosticsFile, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(line["kind"] as? String, "reset")
        XCTAssertEqual(line["provider"] as? String, Provider.openai.rawValue)
        XCTAssertEqual(line["accountID"] as? String, OpenAIFixtures.account.id.uuidString)
        XCTAssertEqual(line["status"] as? Int, 503)
        XCTAssertEqual(line["retryAfterSeconds"] as? Int, 30)
        XCTAssertEqual(line["url"] as? String, OpenAIEndpoints.resetConsumeURL.absoluteString)
        XCTAssertEqual(line["bodyPrefix"] as? String, "unavailable")
        let headers = try XCTUnwrap(line["requestHeaders"] as? [String: String])
        XCTAssertFalse(headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame })
        XCTAssertFalse(text.contains("access-token-123"))
        XCTAssertFalse(text.contains(attemptID.uuidString.lowercased()), "the request body is never logged")
    }

    func test200WritesNoDiagnosticsLine() async throws {
        let diagnostics = Diagnostics(paths: paths)
        _ = try await reset([.json(#"{"code":"no_credit"}"#)], diagnostics: diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.diagnosticsFile.path))
    }
}
