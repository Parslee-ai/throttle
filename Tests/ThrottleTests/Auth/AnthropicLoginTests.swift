import XCTest
@testable import Throttle

final class AnthropicLoginTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private static let tokenBody = """
    {"access_token":"sk-ant-oat01-access","refresh_token":"sk-ant-ort01-refresh","expires_in":28800,\
    "refresh_token_expires_in":2592000,"scope":"user:profile user:inference","token_type":"Bearer"}
    """
    private static let profileBody = """
    {"account":{"email":"person@example.com"},"organization":{"name":"Example Org"}}
    """

    private func makeLogin(client: AuthMockHTTPClient, ports: [UInt16] = AnthropicLogin.defaultPorts) -> AnthropicLogin {
        AnthropicLogin(
            client: client,
            provider: AnthropicProvider(client: client, now: { [fixedNow] in fixedNow }),
            preferredPorts: ports,
            now: { [fixedNow] in fixedNow }
        )
    }

    private func requireFree(_ ports: [UInt16]) throws {
        for port in ports where !AuthTestSupport.isPortFree(port) {
            throw XCTSkip("port \(port) is in use on this machine")
        }
    }

    // MARK: Token mapping (ISC-61)

    func testCredentialStoresRefreshTokenExpiry() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.tokenBody.utf8)) as? [String: Any])
        let credential = try AnthropicLogin.credential(from: object, now: fixedNow)
        XCTAssertEqual(credential.expiresAt, fixedNow.addingTimeInterval(28_800))
        XCTAssertEqual(credential.refreshTokenExpiresAt, fixedNow.addingTimeInterval(2_592_000))
        XCTAssertNil(credential.idToken)
    }

    // MARK: Authorize URL

    func testManualModeAuthorizeURLHasExactParameters() async throws {
        let login = makeLogin(client: AuthMockHTTPClient(responses: []))
        let session = try await login.begin(mode: .manualCode)
        XCTAssertTrue(session.expectsManualCode)

        let url = session.authorizeURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "platform.claude.com")
        XCTAssertEqual(url.path, "/oauth/authorize")

        let query = AuthTestSupport.query(url)
        XCTAssertEqual(query.map(\.0), [
            "code", "client_id", "response_type", "redirect_uri", "scope",
            "code_challenge", "code_challenge_method", "state",
        ])
        let values = Dictionary(uniqueKeysWithValues: query)
        XCTAssertEqual(values["code"], "true")
        XCTAssertEqual(values["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(values["scope"], AnthropicLogin.scope)
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"]?.count, 43)
        XCTAssertEqual(values["state"]?.count, 43)
    }

    func testLoopbackModeAuthorizeURLUsesLocalhostRedirect() async throws {
        try requireFree(AnthropicLogin.defaultPorts)
        let login = makeLogin(client: AuthMockHTTPClient(responses: []))
        let session = try await login.begin(mode: .loopback)
        XCTAssertFalse(session.expectsManualCode)

        let values = Dictionary(uniqueKeysWithValues: AuthTestSupport.query(session.authorizeURL))
        XCTAssertNil(values["code"], "loopback mode must not request the hosted code page")
        XCTAssertEqual(values["redirect_uri"], "http://localhost:1456/callback")
        XCTAssertEqual(values["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(values["scope"], AnthropicLogin.scope)
        XCTAssertEqual(values["code_challenge_method"], "S256")

        // Tear the listener down by cancelling the completion.
        let completion = Task { try await session.completion(nil) }
        completion.cancel()
        _ = try? await completion.value
        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1456) }
        XCTAssertTrue(released)
    }

    func testLoopbackModeFallsBackTo1458AndReportsBusyPorts() async throws {
        try requireFree(AnthropicLogin.defaultPorts)
        let held1456 = try XCTUnwrap(HeldPort(1456))
        defer { held1456.close() }

        let login = makeLogin(client: AuthMockHTTPClient(responses: []))
        let session = try await login.begin(mode: .loopback)
        XCTAssertEqual(AuthTestSupport.queryValue(session.authorizeURL, "redirect_uri"), "http://localhost:1458/callback")
        let completion = Task { try await session.completion(nil) }
        completion.cancel()
        _ = try? await completion.value

        let held1458 = try XCTUnwrap(HeldPort(1458))
        defer { held1458.close() }
        do {
            _ = try await login.begin(mode: .loopback)
            XCTFail("expected portsBusy")
        } catch LoginError.portsBusy(let ports) {
            XCTAssertEqual(ports, [1456, 1458])
        }
    }

    // MARK: Pasted code

    func testPastedCodeSplitsOnHash() throws {
        let parsed = try AnthropicLogin.parsePastedCode("abc123#state-xyz", fallbackState: "ours")
        XCTAssertEqual(parsed.code, "abc123")
        XCTAssertEqual(parsed.state, "state-xyz")

        let bare = try AnthropicLogin.parsePastedCode("  abc123\n", fallbackState: "ours")
        XCTAssertEqual(bare.code, "abc123")
        XCTAssertEqual(bare.state, "ours")
    }

    func testPastedSetupTokenIsRejected() {
        XCTAssertThrowsError(try AnthropicLogin.parsePastedCode("sk-ant-oat01-abcdef#x", fallbackState: "s")) { error in
            XCTAssertEqual(error as? LoginError, .setupTokenNotSupported)
        }
        XCTAssertThrowsError(try AnthropicLogin.parsePastedCode("sk-ant-api03-abcdef", fallbackState: "s")) { error in
            XCTAssertEqual(error as? LoginError, .setupTokenNotSupported)
        }
    }

    func testEmptyPasteIsMalformed() {
        XCTAssertThrowsError(try AnthropicLogin.parsePastedCode("", fallbackState: "s")) { error in
            XCTAssertEqual(error as? LoginError, .malformedCode)
        }
        XCTAssertThrowsError(try AnthropicLogin.parsePastedCode(nil, fallbackState: "s")) { error in
            XCTAssertEqual(error as? LoginError, .malformedCode)
        }
        XCTAssertThrowsError(try AnthropicLogin.parsePastedCode("#state", fallbackState: "s")) { error in
            XCTAssertEqual(error as? LoginError, .malformedCode)
        }
    }

    func testStateMismatchAbortsAndSendsNothing() async throws {
        let client = AuthMockHTTPClient(responses: [AuthTestSupport.json(Self.tokenBody)])
        let session = try await makeLogin(client: client).begin(mode: .manualCode)
        do {
            _ = try await session.completion("code#not-our-state")
            XCTFail("expected stateMismatch")
        } catch LoginError.stateMismatch {
            // expected
        }
        XCTAssertTrue(client.requests.isEmpty, "no token request may be sent on a state mismatch")
    }

    // MARK: Exchange

    func testManualExchangeSendsExactFormBodyThenReadsProfile() async throws {
        let client = AuthMockHTTPClient(responses: [
            AuthTestSupport.json(Self.tokenBody),
            AuthTestSupport.json(Self.profileBody),
        ])
        let session = try await makeLogin(client: client).begin(mode: .manualCode)
        let state = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "state"))
        let challenge = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "code_challenge"))

        let result = try await session.completion("the-code#\(state)")

        XCTAssertEqual(client.requests.count, 2)
        let exchange = client.requests[0]
        XCTAssertEqual(exchange.url, URL(string: "https://platform.claude.com/v1/oauth/token"))
        XCTAssertEqual(exchange.httpMethod, "POST")
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let fields = client.formFields(ofRequest: 0)
        XCTAssertEqual(fields.map(\.0), ["grant_type", "code", "state", "redirect_uri", "client_id", "code_verifier"])
        let values = Dictionary(uniqueKeysWithValues: fields)
        XCTAssertEqual(values["grant_type"], "authorization_code")
        XCTAssertEqual(values["code"], "the-code")
        XCTAssertEqual(values["state"], state)
        XCTAssertEqual(values["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(values["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        let verifier = try XCTUnwrap(values["code_verifier"])
        XCTAssertEqual(PKCE.challenge(for: verifier), challenge, "verifier must match the challenge we sent")

        XCTAssertEqual(client.requests[1].url, AnthropicEndpoints.profile)
        XCTAssertEqual(client.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-access")

        XCTAssertEqual(result.credential.accessToken, "sk-ant-oat01-access")
        XCTAssertEqual(result.credential.refreshToken, "sk-ant-ort01-refresh")
        XCTAssertEqual(result.credential.expiresAt, fixedNow.addingTimeInterval(28800))
        XCTAssertEqual(result.credential.scopes, ["user:profile", "user:inference"])
        XCTAssertNil(result.credential.accountID)
        XCTAssertEqual(result.email, "person@example.com")
        XCTAssertEqual(result.planLabel, "Example Org")
    }

    func testExchangeRetriesAtConsoleOn400() async throws {
        let client = AuthMockHTTPClient(responses: [
            AuthTestSupport.json(400, #"{"error":"invalid_request"}"#),
            AuthTestSupport.json(Self.tokenBody),
            AuthTestSupport.json(200, "{}"),
        ])
        let session = try await makeLogin(client: client).begin(mode: .manualCode)
        let state = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "state"))
        let result = try await session.completion("code#\(state)")

        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(client.requests[0].url, URL(string: "https://platform.claude.com/v1/oauth/token"))
        XCTAssertEqual(client.requests[1].url, URL(string: "https://console.anthropic.com/v1/oauth/token"))
        XCTAssertEqual(client.requests[0].httpBody, client.requests[1].httpBody, "retry sends the same body")
        XCTAssertEqual(result.email, "Claude account", "empty profile falls back to a generic label")
        XCTAssertNil(result.planLabel)
    }

    func testExchangeFailureIsReportedRedacted() async throws {
        let client = AuthMockHTTPClient(responses: [
            AuthTestSupport.json(400, #"{"error":"invalid_grant","error_description":"bad code sk-ant-oat01-leak"}"#),
            AuthTestSupport.json(401, #"{"error":{"type":"authentication_error","message":"nope"}}"#),
        ])
        let session = try await makeLogin(client: client).begin(mode: .manualCode)
        let state = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "state"))
        do {
            _ = try await session.completion("code#\(state)")
            XCTFail("expected tokenExchange")
        } catch LoginError.tokenExchange(let reason) {
            XCTAssertEqual(reason, "HTTP 401 (authentication_error: nope)")
            XCTAssertFalse(reason.contains("leak"))
        }
    }

    func testLoopbackCompletionExchangesTheCallbackCode() async throws {
        try requireFree(AnthropicLogin.defaultPorts)
        let client = AuthMockHTTPClient(responses: [
            AuthTestSupport.json(Self.tokenBody),
            AuthTestSupport.json(Self.profileBody),
        ])
        let session = try await makeLogin(client: client).begin(mode: .loopback)
        let state = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "state"))
        let redirect = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "redirect_uri"))
        XCTAssertEqual(redirect, "http://localhost:1456/callback")

        let completion = Task { try await session.completion(nil) }
        let browser = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:1456/callback?code=loop-code&state=\(state)")!)
        XCTAssertEqual(browser.status, 200)

        let result = try await completion.value
        XCTAssertEqual(result.email, "person@example.com")
        let values = Dictionary(uniqueKeysWithValues: client.formFields(ofRequest: 0))
        XCTAssertEqual(values["code"], "loop-code")
        XCTAssertEqual(values["redirect_uri"], "http://localhost:1456/callback")
        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1456) }
        XCTAssertTrue(released)
    }

    func testLoopbackStateMismatchAbortsAndSendsNothing() async throws {
        try requireFree(AnthropicLogin.defaultPorts)
        let client = AuthMockHTTPClient(responses: [AuthTestSupport.json(Self.tokenBody)])
        let session = try await makeLogin(client: client).begin(mode: .loopback)

        let completion = Task { try await session.completion(nil) }
        _ = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:1456/callback?code=x&state=forged")!)
        do {
            _ = try await completion.value
            XCTFail("expected stateMismatch")
        } catch LoginError.stateMismatch {
            // expected
        }
        XCTAssertTrue(client.requests.isEmpty)
        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1456) }
        XCTAssertTrue(released)
    }
}
