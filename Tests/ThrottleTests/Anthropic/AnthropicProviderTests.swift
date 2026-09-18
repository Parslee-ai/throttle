import XCTest
@testable import Throttle

final class AnthropicProviderTests: XCTestCase {
    private let fixedNow = Date.iso("2026-07-13T12:00:00Z")

    private var account: Account {
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, provider: .anthropic, email: "user@example.com", sortIndex: 0)
    }

    private var credential: AccountCredential {
        AccountCredential(
            accessToken: AnthropicSampleSecret.accessToken,
            refreshToken: AnthropicSampleSecret.refreshToken,
            expiresAt: fixedNow.addingTimeInterval(3600),
            accountID: "acct_test",
            scopes: ["user:profile"]
        )
    }

    private func makeProvider(_ client: AnthropicMockHTTPClient) -> AnthropicProvider {
        let now = fixedNow
        return AnthropicProvider(client: client, now: { now })
    }

    // MARK: Request shape (ISC-43)

    func testUsageRequestCarriesExactHeadersAndNoCookies() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-limits"))
        _ = try await makeProvider(client).fetchStatus(account: account, credential: credential)

        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(AnthropicSampleSecret.accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("throttle/"), true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(client.maxBodyLimits, [256 * 1024])
    }

    func testProviderCaseIsAnthropic() {
        XCTAssertEqual(makeProvider(AnthropicMockHTTPClient()).provider, .anthropic)
    }

    // MARK: Success

    func testSuccessBuildsOkStatusFromParsedWindows() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try AnthropicFixtures.data("anthropic-limits"))
        let status = try await makeProvider(client).fetchStatus(account: account, credential: credential)

        XCTAssertEqual(status.accountID, account.id)
        XCTAssertEqual(status.provider, .anthropic)
        XCTAssertEqual(status.email, "user@example.com")
        XCTAssertEqual(status.state, .ok)
        XCTAssertEqual(status.fetchedAt, fixedNow)
        XCTAssertEqual(status.windows.map(\.key), ["5h", "7d", "scoped:Fable", "scoped:Claude Opus"])
    }

    /// ISC-49 through the adapter: a 200 with nothing usable is an error, not `.ok`.
    func testSuccessWithNoWindowsThrows() async {
        let client = AnthropicMockHTTPClient(status: 200, body: Data(#"{"limits":[]}"#.utf8))
        await assertThrows(client) { error in
            guard case UsageError.invalidResponse(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(reason, "no usable windows")
        }
    }

    // MARK: Status mapping (ISC-50..53)

    func testUnauthorizedIsNeedsLogin() async {
        await assertThrows(AnthropicMockHTTPClient(status: 401)) { error in
            guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
        }
    }

    func testForbiddenWithoutAPermissionBodyIsNeedsLogin() async {
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: Data("{}".utf8))) { error in
            guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
        }
    }

    func testForbiddenWithNonJSONBodyIsNeedsLogin() async {
        let html = Data("<html><body>Access denied</body></html>".utf8)
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: html)) { error in
            guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
        }
    }

    /// D-33: the organization refusing this OAuth client is its own error,
    /// carrying the provider's message, not a login problem.
    func testForbiddenWithPermissionErrorIsForbiddenWithReason() async {
        let body = Data(#"{"type":"error","error":{"type":"permission_error","message":"OAuth authentication is currently not allowed for this organization.","details":{"error_code":"oauth_not_allowed_for_organization"}}}"#.utf8)
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: body)) { error in
            guard case UsageError.forbidden(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(reason, "OAuth authentication is currently not allowed for this organization.")
        }
    }

    func testForbiddenWithErrorCodeButNoMessageIsForbidden() async {
        let body = Data(#"{"type":"error","error":{"type":"something_new","details":{"error_code":"oauth_not_allowed_for_organization"}}}"#.utf8)
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: body)) { error in
            guard case UsageError.forbidden(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(reason, "Not allowed by organization (oauth_not_allowed_for_organization)")
        }
    }

    func testForbiddenReasonIsRedacted() async {
        let body = Data(#"{"type":"error","error":{"type":"permission_error","message":"Denied for Bearer sk-ant-oat01-secret-value-1234567890"}}"#.utf8)
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: body)) { error in
            guard case UsageError.forbidden(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertFalse(reason.contains("secret"), reason)
            XCTAssertTrue(reason.contains("[redacted]"), reason)
        }
    }

    func testOtherErrorTypesOn403AreStillNeedsLogin() async {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"Invalid bearer token"}}"#.utf8)
        await assertThrows(AnthropicMockHTTPClient(status: 403, body: body)) { error in
            guard case UsageError.needsLogin = error else { return XCTFail("got \(error)") }
        }
    }

    func testRateLimitedWithRetryAfterSeconds() async {
        let client = AnthropicMockHTTPClient(status: 429, headers: ["Retry-After": "120"])
        await assertThrows(client) { error in
            guard case UsageError.rateLimited(let retryAfter) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(retryAfter, 120)
        }
    }

    func testRateLimitedWithRetryAfterHTTPDate() async {
        // 15 minutes after the injected clock.
        let client = AnthropicMockHTTPClient(status: 429, headers: ["retry-after": "Mon, 13 Jul 2026 12:15:00 GMT"])
        await assertThrows(client) { error in
            guard case UsageError.rateLimited(let retryAfter) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(try XCTUnwrap(retryAfter), 900, accuracy: 0.5)
        }
    }

    func testRateLimitedWithoutRetryAfterIsNil() async {
        await assertThrows(AnthropicMockHTTPClient(status: 429)) { error in
            guard case UsageError.rateLimited(let retryAfter) = error else { return XCTFail("got \(error)") }
            XCTAssertNil(retryAfter)
        }
    }

    func testRedirectIsRedirectError() async {
        let client = AnthropicMockHTTPClient(status: 302, headers: ["Location": "https://claude.ai/login"])
        await assertThrows(client) { error in
            guard case UsageError.redirect = error else { return XCTFail("got \(error)") }
        }
    }

    func testOtherStatusIsInvalidResponseWithCode() async {
        await assertThrows(AnthropicMockHTTPClient(status: 503)) { error in
            guard case UsageError.invalidResponse(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(reason, "HTTP 503")
        }
    }

    func testOversizedBodyPropagatesTooLarge() async {
        await assertThrows(AnthropicMockHTTPClient(throwing: UsageError.tooLarge)) { error in
            guard case UsageError.tooLarge = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: Redaction (ISC-131)

    /// A transport failure that echoes its request must not leak the bearer
    /// token through `String(describing:)`, which is what ends up in logs.
    func testTransportErrorDescriptionNeverContainsToken() async {
        struct ChattyTransportError: Error, CustomStringConvertible {
            let request: URLRequest
            var description: String {
                "failed: \(request.url?.absoluteString ?? "") headers=\(request.allHTTPHeaderFields ?? [:])"
            }
        }
        var echoed = URLRequest(url: AnthropicEndpoints.usage)
        echoed.setValue("Bearer \(AnthropicSampleSecret.accessToken)", forHTTPHeaderField: "Authorization")
        let client = AnthropicMockHTTPClient(throwing: UsageError.transport(ChattyTransportError(request: echoed)))

        await assertThrows(client) { error in
            guard case UsageError.transport(let inner) = error else { return XCTFail("got \(error)") }
            for rendering in [String(describing: error), String(reflecting: error), String(describing: inner), inner.localizedDescription] {
                XCTAssertFalse(rendering.contains(AnthropicSampleSecret.accessToken), "leaked in: \(rendering)")
            }
            XCTAssertTrue(String(describing: inner).contains("[redacted]"))
        }
    }

    // MARK: Profile (ISC-54)

    func testProfileParsesNestedEmailAndOrganization() async throws {
        let body = #"{"account":{"uuid":"u1","email":"nested@example.com"},"organization":{"uuid":"o1","name":"Example Org"}}"#
        let client = AnthropicMockHTTPClient(status: 200, body: Data(body.utf8))
        let profile = try await makeProvider(client).fetchProfile(credential: credential)
        XCTAssertEqual(profile.email, "nested@example.com")
        XCTAssertEqual(profile.organizationName, "Example Org")

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(AnthropicSampleSecret.accessToken)")
    }

    func testProfileFallsBackToTopLevelEmail() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: Data(#"{"email":"flat@example.com"}"#.utf8))
        let profile = try await makeProvider(client).fetchProfile(credential: credential)
        XCTAssertEqual(profile.email, "flat@example.com")
        XCTAssertNil(profile.organizationName)
    }

    func testProfileReturnsNilsOnNon200() async throws {
        let client = AnthropicMockHTTPClient(status: 404, body: Data("not found".utf8))
        let profile = try await makeProvider(client).fetchProfile(credential: credential)
        XCTAssertNil(profile.email)
        XCTAssertNil(profile.organizationName)
    }

    // MARK: Refresh

    func testRefreshJSONSuccessRotatesCredential() async throws {
        let body = """
        {"access_token":"\(AnthropicSampleSecret.rotatedAccess)","refresh_token":"\(AnthropicSampleSecret.rotatedRefresh)","expires_in":28800,"scope":"user:profile user:inference","token_type":"Bearer"}
        """
        let client = AnthropicMockHTTPClient(status: 200, body: Data(body.utf8))
        let rotated = try await makeProvider(client).refresh(credential: credential)

        XCTAssertEqual(rotated.accessToken, AnthropicSampleSecret.rotatedAccess)
        XCTAssertEqual(rotated.refreshToken, AnthropicSampleSecret.rotatedRefresh)
        XCTAssertEqual(rotated.expiresAt, fixedNow.addingTimeInterval(28_800))
        XCTAssertEqual(rotated.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(rotated.accountID, "acct_test")

        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://console.anthropic.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(sent?["grant_type"], "refresh_token")
        XCTAssertEqual(sent?["refresh_token"], AnthropicSampleSecret.refreshToken)
        XCTAssertEqual(sent?["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    func testRefreshStoresRefreshTokenExpiryWhenPresent() async throws {
        let body = #"{"access_token":"\#(AnthropicSampleSecret.rotatedAccess)","expires_in":3600,"refresh_token_expires_in":2592000}"#
        let client = AnthropicMockHTTPClient(status: 200, body: Data(body.utf8))
        let rotated = try await makeProvider(client).refresh(credential: credential)
        XCTAssertEqual(rotated.refreshTokenExpiresAt, fixedNow.addingTimeInterval(2_592_000), "ISC-61")
    }

    func testRefreshKeepsOldRefreshTokenAndScopesWhenOmitted() async throws {
        let body = #"{"access_token":"\#(AnthropicSampleSecret.rotatedAccess)","expires_in":3600}"#
        let client = AnthropicMockHTTPClient(status: 200, body: Data(body.utf8))
        let rotated = try await makeProvider(client).refresh(credential: credential)
        XCTAssertEqual(rotated.refreshToken, AnthropicSampleSecret.refreshToken)
        XCTAssertEqual(rotated.scopes, ["user:profile"])
        XCTAssertEqual(rotated.expiresAt, fixedNow.addingTimeInterval(3600))
    }

    func testRefresh400FallsBackToFormEncodedPlatformEndpoint() async throws {
        let client = AnthropicMockHTTPClient()
        client.enqueue(status: 400, body: Data(#"{"error":"invalid_request","error_description":"unsupported content type"}"#.utf8))
        client.enqueue(status: 200, body: Data(#"{"access_token":"\#(AnthropicSampleSecret.rotatedAccess)","refresh_token":"\#(AnthropicSampleSecret.rotatedRefresh)","expires_in":3600}"#.utf8))

        let rotated = try await makeProvider(client).refresh(credential: credential)
        XCTAssertEqual(rotated.accessToken, AnthropicSampleSecret.rotatedAccess)

        XCTAssertEqual(client.requests.count, 2)
        let fallback = client.requests[1]
        XCTAssertEqual(fallback.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(fallback.httpMethod, "POST")
        XCTAssertEqual(fallback.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = String(decoding: try XCTUnwrap(fallback.httpBody), as: UTF8.self)
        let pairs = Dictionary(uniqueKeysWithValues: form.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : "")
        })
        XCTAssertEqual(pairs["grant_type"], "refresh_token")
        XCTAssertEqual(pairs["refresh_token"], AnthropicSampleSecret.refreshToken)
        XCTAssertEqual(pairs["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    func testRefreshInvalidGrantIsNeedsLoginWithoutFallback() async {
        let client = AnthropicMockHTTPClient(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"refresh token revoked"}"#.utf8))
        do {
            _ = try await makeProvider(client).refresh(credential: credential)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
            XCTAssertEqual(client.requests.count, 1, "a dead refresh token is not retried on the fallback endpoint")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testRefresh401IsNeedsLogin() async {
        let client = AnthropicMockHTTPClient(status: 401, body: Data("{}".utf8))
        do {
            _ = try await makeProvider(client).refresh(credential: credential)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testRefreshWithoutRefreshTokenIsNeedsLogin() async {
        let client = AnthropicMockHTTPClient()
        do {
            _ = try await makeProvider(client).refresh(credential: AccountCredential(accessToken: AnthropicSampleSecret.accessToken))
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
            XCTAssertTrue(client.requests.isEmpty)
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: Helpers

    private func assertThrows(
        _ client: AnthropicMockHTTPClient,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (Error) throws -> Void
    ) async {
        do {
            _ = try await makeProvider(client).fetchStatus(account: account, credential: credential)
            XCTFail("expected an error", file: file, line: line)
        } catch {
            do {
                try check(error)
            } catch {
                XCTFail("check threw \(error)", file: file, line: line)
            }
        }
    }
}
