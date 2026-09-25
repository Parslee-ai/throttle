import XCTest
@testable import Throttle

final class OpenAIProviderTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_787_000_000)

    private func makeProvider(_ client: OpenAIMockHTTPClient) -> OpenAIProvider {
        let now = fixedNow
        return OpenAIProvider(client: client, now: { now })
    }

    private var credential: AccountCredential {
        AccountCredential(accessToken: "access-token-123", refreshToken: "refresh-token-456", accountID: "acct-789")
    }

    func testProviderCase() {
        XCTAssertEqual(OpenAIProvider(client: OpenAIMockHTTPClient(responses: [])).provider, .openai)
    }

    // MARK: - Request shape (ISC-70)

    func testUsageRequestHeaders() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(try String(decoding: OpenAIFixtures.whamUsage(), as: UTF8.self))])
        let provider = makeProvider(client)

        _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)

        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, URL(string: "https://chatgpt.com/backend-api/wham/usage"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex_cli_rs/0.145.0 (throttle)")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(client.maxBodyBytesSeen, [256 * 1024])
    }

    func testAccountIDHeaderOmittedWhenCredentialHasNone() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(try String(decoding: OpenAIFixtures.whamUsage(), as: UTF8.self))])
        let provider = makeProvider(client)
        let noAccount = AccountCredential(accessToken: "tok")

        _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: noAccount)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "chatgpt-account-id"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // MARK: - Status mapping

    func testSuccessProducesOKStatusWithPayloadEmail() async throws {
        let client = OpenAIMockHTTPClient(responses: [.json(try String(decoding: OpenAIFixtures.whamUsage(), as: UTF8.self))])
        let provider = makeProvider(client)

        let (status, snapshot) = try await provider.fetchDetailed(account: OpenAIFixtures.account, credential: credential)

        XCTAssertEqual(status.accountID, OpenAIFixtures.account.id)
        XCTAssertEqual(status.provider, .openai)
        XCTAssertEqual(status.email, "redacted@example.com", "payload email wins over the stored label")
        XCTAssertEqual(status.state, .ok)
        XCTAssertEqual(status.fetchedAt, fixedNow)
        XCTAssertEqual(status.windows.map(\.label), ["Weekly", "GPT-5.3-Codex-Spark 5h", "GPT-5.3-Codex-Spark Weekly"], "primary windows first, then extra lanes so the UI can fold them")
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.additionalWindows.count, 2)
        XCTAssertEqual(status.planLabel, "pro", "ISC-74: the plan badge rides on the status")
        XCTAssertEqual(status.resetCreditsAvailable, 1, "the manual-reset count rides on the status")
        XCTAssertEqual(status.windows.filter(\.isLane).count, 2, "extra lanes carry the lane prefix so the bar can skip them")
    }

    func testStatusPlanLabelIsNilWhenPayloadHasNoPlan() async throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_at": 5}, "secondary_window": null}}
        """
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(json)]))
        let status = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
        XCTAssertNil(status.planLabel)
        XCTAssertNil(status.resetCreditsAvailable)
    }

    func testMissingPayloadEmailFallsBackToAccountEmail() async throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_at": 5}, "secondary_window": null}}
        """
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(json)]))
        let status = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
        XCTAssertEqual(status.email, "stored@example.com")
    }

    func test401IsNeedsLogin() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(401, #"{"detail":"Unauthorized"}"#)]))
        await assertThrows(needsLogin: { try await provider.fetchStatus(account: OpenAIFixtures.account, credential: self.credential) })
    }

    /// ISC-75: a limit-reached 403 still carries a valid usage body.
    func test403WithValidBodyIsParsedAsUsage() async throws {
        let json = OpenAIFixtures.synthetic(primarySeconds: 18_000, secondarySeconds: 604_800)
            .replacingOccurrences(of: "\"limit_reached\": false", with: "\"limit_reached\": true")
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(403, json)]))

        let status = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)

        XCTAssertEqual(status.state, .ok)
        XCTAssertEqual(status.windows.map(\.key), ["5h", "7d"])
    }

    func test403WithHTMLIsNeedsLogin() async {
        let html = HTTPResponse.response(403, headers: ["Content-Type": "text/html"], body: "<html><body>Access denied</body></html>")
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [html]))
        await assertThrows(needsLogin: { try await provider.fetchStatus(account: OpenAIFixtures.account, credential: self.credential) })
    }

    /// D-33: a 403 whose body is a permission error is the organization
    /// refusing this client, not a login problem.
    func test403WithPermissionErrorIsForbidden() async {
        let body = #"{"error":{"type":"permission_error","message":"This organization does not allow this client.","code":"org_forbidden"}}"#
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(403, body)]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected forbidden")
        } catch UsageError.forbidden(let reason) {
            XCTAssertEqual(reason, "This organization does not allow this client.")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test403WithUnrelatedJSONErrorIsNeedsLogin() async {
        let body = #"{"error":{"type":"invalid_request_error","message":"bad"}}"#
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(403, body)]))
        await assertThrows(needsLogin: { try await provider.fetchStatus(account: OpenAIFixtures.account, credential: self.credential) })
    }

    func test429CarriesRetryAfter() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [
            .response(429, headers: ["Retry-After": "120"], body: "slow down"),
        ]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func test429WithoutHeaderHasNilRetryAfter() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.response(429)]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected rateLimited")
        } catch UsageError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func test302IsRedirect() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [
            .response(302, headers: ["Location": "https://chatgpt.com/auth/login"]),
        ]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected redirect")
        } catch UsageError.redirect {
        } catch {
            XCTFail("expected redirect, got \(error)")
        }
    }

    func test500IsInvalidResponseWithCode() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.response(503, body: "upstream")]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected invalidResponse")
        } catch UsageError.invalidResponse(let reason) {
            XCTAssertEqual(reason, "HTTP 503")
        } catch {
            XCTFail("expected invalidResponse, got \(error)")
        }
    }

    func testTransportErrorsPropagate() async {
        struct Boom: Error {}
        let provider = makeProvider(OpenAIMockHTTPClient(results: [.failure(UsageError.transport(Boom()))]))
        do {
            _ = try await provider.fetchStatus(account: OpenAIFixtures.account, credential: credential)
            XCTFail("expected transport")
        } catch UsageError.transport {
        } catch {
            XCTFail("expected transport, got \(error)")
        }
    }

    // MARK: - Refresh (ISC-83)

    func testRefreshSendsExactFormBodyAndAppliesResponse() async throws {
        let idToken = try OpenAIFixtures.unsignedJWT(payload: [
            "email": "person@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-id-token", "chatgpt_plan_type": "pro"],
        ])
        let body = """
        {"id_token": "\(idToken)", "access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600, "token_type": "Bearer"}
        """
        let client = OpenAIMockHTTPClient(responses: [.json(body)])
        let provider = makeProvider(client)

        let rotated = try await provider.refresh(credential: credential)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, URL(string: "https://auth.openai.com/oauth/token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
            "grant_type=refresh_token&refresh_token=refresh-token-456&client_id=app_EMoamEEZ73f0CkXaXp7hrann&scope=openid%20profile%20email%20offline_access"
        )

        XCTAssertEqual(rotated.accessToken, "new-access")
        XCTAssertEqual(rotated.refreshToken, "new-refresh")
        XCTAssertEqual(rotated.accountID, "acct-from-id-token")
        XCTAssertEqual(rotated.expiresAt, fixedNow.addingTimeInterval(3600))
        XCTAssertEqual(rotated.idToken, idToken, "ISC-81: the id_token is stored with the credential")
    }

    func testRefreshKeepsOldRefreshTokenAndAccountIDWhenOmitted() async throws {
        let accessToken = try OpenAIFixtures.unsignedJWT(payload: ["exp": 1_790_000_000])
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(#"{"access_token": "\#(accessToken)"}"#)]))

        let rotated = try await provider.refresh(credential: credential)

        XCTAssertEqual(rotated.accessToken, accessToken)
        XCTAssertEqual(rotated.refreshToken, "refresh-token-456")
        XCTAssertEqual(rotated.accountID, "acct-789")
        XCTAssertEqual(rotated.expiresAt, Date(timeIntervalSince1970: 1_790_000_000), "expiry falls back to the access token exp claim")
    }

    func testRefreshPercentEncodesTokenCharacters() {
        let body = OpenAIProvider.refreshFormBody(refreshToken: "a+b/c=d e&f")
        XCTAssertTrue(body.hasPrefix("grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3Dd%20e%26f&client_id="))
    }

    func testRefreshInvalidGrantIsNeedsLogin() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [
            .json(400, #"{"error": "invalid_grant", "error_description": "refresh token revoked"}"#),
        ]))
        await assertThrows(needsLogin: { try await provider.refresh(credential: self.credential) })
    }

    func testRefresh200WithInvalidGrantBodyIsNeedsLogin() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(200, #"{"error": "invalid_grant"}"#)]))
        await assertThrows(needsLogin: { try await provider.refresh(credential: self.credential) })
    }

    func testRefresh401IsNeedsLogin() async {
        let provider = makeProvider(OpenAIMockHTTPClient(responses: [.json(401, "{}")]))
        await assertThrows(needsLogin: { try await provider.refresh(credential: self.credential) })
    }

    func testRefreshWithoutRefreshTokenIsNeedsLoginWithoutNetwork() async {
        let client = OpenAIMockHTTPClient(responses: [])
        let provider = makeProvider(client)
        await assertThrows(needsLogin: { try await provider.refresh(credential: AccountCredential(accessToken: "only-access")) })
        XCTAssertTrue(client.requests.isEmpty)
    }

    // MARK: - ISC-77: read-only guarantee

    /// The adapter's source never names the completions endpoint. The one
    /// spending path, the reset consume URL, is spelled out only in
    /// `OpenAIEndpoints.swift`, and only `OpenAIProvider.swift` refers to it,
    /// from `useReset`, which runs on an explicit user action.
    func testOpenAISourcesNeverNameSpendingEndpoints() throws {
        try RepoAudit.requireRepositoryAccess()
        let directory = OpenAIFixtures.openAISourcesDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        XCTAssertEqual(Set(files), ["OpenAIEndpoints.swift", "JWTClaims.swift", "OpenAIProvider.swift", "OpenAIUsageParser.swift"])

        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("/responses"), "\(file) mentions /responses")
            if file != "OpenAIEndpoints.swift" {
                XCTAssertFalse(text.contains("rate-limit-reset-credits"), "\(file) spells out the reset path")
            }
            if file != "OpenAIEndpoints.swift" && file != "OpenAIProvider.swift" {
                XCTAssertFalse(text.lowercased().contains("consume"), "\(file) mentions consume")
            }
        }
        let provider = try String(contentsOf: directory.appendingPathComponent("OpenAIProvider.swift"), encoding: .utf8)
        XCTAssertEqual(
            provider.components(separatedBy: "URLRequest(url: OpenAIEndpoints.resetConsumeURL)").count - 1, 1,
            "exactly one request is built for the consume URL"
        )
    }

    // MARK: - Helpers

    private func assertThrows<T>(
        needsLogin body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected needsLogin", file: file, line: line)
        } catch UsageError.needsLogin {
        } catch {
            XCTFail("expected needsLogin, got \(error)", file: file, line: line)
        }
    }
}
