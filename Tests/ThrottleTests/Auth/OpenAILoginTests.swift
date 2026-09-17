import XCTest
@testable import Throttle

final class OpenAILoginTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLogin(client: AuthMockHTTPClient) -> OpenAILogin {
        OpenAILogin(
            client: client,
            provider: OpenAIProvider(client: client, now: { [fixedNow] in fixedNow }),
            now: { [fixedNow] in fixedNow }
        )
    }

    private func requirePortFree() throws {
        guard AuthTestSupport.isPortFree(1455) else {
            throw XCTSkip("port 1455 is in use on this machine")
        }
    }

    private func idToken(accountID: String? = "acct_123", email: String? = "codex@example.com", plan: String? = "plus") -> String {
        var payload: [String: Any] = ["exp": 1_800_003_600, "sub": "user"]
        if let email { payload["email"] = email }
        var auth: [String: Any] = [:]
        if let accountID { auth["chatgpt_account_id"] = accountID }
        if let plan { auth["chatgpt_plan_type"] = plan }
        payload["https://api.openai.com/auth"] = auth
        return AuthTestSupport.unsignedJWT(payload)
    }

    private func tokenBody(idToken: String?, accessToken: String = "eyJ-access", expiresIn: Int? = 3600) -> String {
        var object: [String: Any] = ["access_token": accessToken, "refresh_token": "rt-1", "token_type": "Bearer"]
        if let idToken { object["id_token"] = idToken }
        if let expiresIn { object["expires_in"] = expiresIn }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Authorize URL

    func testAuthorizeURLHasExactParameters() async throws {
        try requirePortFree()
        let session = try await makeLogin(client: AuthMockHTTPClient(responses: [])).begin(mode: .loopback)
        XCTAssertFalse(session.expectsManualCode)

        let url = session.authorizeURL
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        let query = AuthTestSupport.query(url)
        XCTAssertEqual(query.map(\.0), [
            "response_type", "client_id", "redirect_uri", "scope", "code_challenge",
            "code_challenge_method", "state", "id_token_add_organizations", "codex_cli_simplified_flow",
        ])
        let values = Dictionary(uniqueKeysWithValues: query)
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(values["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(values["scope"], "openid profile email offline_access")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"]?.count, 43)
        XCTAssertEqual(values["state"]?.count, 43)
        XCTAssertEqual(values["id_token_add_organizations"], "true")
        XCTAssertEqual(values["codex_cli_simplified_flow"], "true")
        XCTAssertTrue(url.absoluteString.contains("scope=openid%20profile%20email%20offline_access"))

        let completion = Task { try await session.completion(nil) }
        completion.cancel()
        _ = try? await completion.value
        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1455) }
        XCTAssertTrue(released)
    }

    func testManualModeIsTreatedAsLoopback() async throws {
        try requirePortFree()
        let session = try await makeLogin(client: AuthMockHTTPClient(responses: [])).begin(mode: .manualCode)
        XCTAssertFalse(session.expectsManualCode)
        XCTAssertEqual(AuthTestSupport.queryValue(session.authorizeURL, "redirect_uri"), "http://localhost:1455/auth/callback")
        let completion = Task { try await session.completion(nil) }
        completion.cancel()
        _ = try? await completion.value
        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1455) }
        XCTAssertTrue(released)
    }

    func testBusyPort1455NamesThePortAndTheCodexCLI() async throws {
        try requirePortFree()
        let held = try XCTUnwrap(HeldPort(1455))
        defer { held.close() }
        do {
            _ = try await makeLogin(client: AuthMockHTTPClient(responses: [])).begin(mode: .loopback)
            XCTFail("expected portsBusy")
        } catch LoginError.portsBusy(let ports) {
            XCTAssertEqual(ports, [1455])
            let message = LoginError.portsBusy(ports).localizedDescription
            XCTAssertTrue(message.contains("1455"), message)
            XCTAssertTrue(message.contains("Codex CLI"), message)
        }
    }

    // MARK: Exchange

    func testExchangeSendsExactFormBodyAndExtractsClaims() async throws {
        try requirePortFree()
        let client = AuthMockHTTPClient(responses: [AuthTestSupport.json(tokenBody(idToken: idToken()))])
        let session = try await makeLogin(client: client).begin(mode: .loopback)
        let state = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "state"))
        let challenge = try XCTUnwrap(AuthTestSupport.queryValue(session.authorizeURL, "code_challenge"))

        let completion = Task { try await session.completion(nil) }
        let browser = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:1455/auth/callback?code=oa-code&state=\(state)")!)
        XCTAssertEqual(browser.status, 200)
        let result = try await completion.value

        XCTAssertEqual(client.requests.count, 1)
        let exchange = client.requests[0]
        XCTAssertEqual(exchange.url, URL(string: "https://auth.openai.com/oauth/token"))
        XCTAssertEqual(exchange.httpMethod, "POST")
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let fields = client.formFields(ofRequest: 0)
        XCTAssertEqual(fields.map(\.0), ["grant_type", "code", "redirect_uri", "client_id", "code_verifier"])
        let values = Dictionary(uniqueKeysWithValues: fields)
        XCTAssertEqual(values["grant_type"], "authorization_code")
        XCTAssertEqual(values["code"], "oa-code")
        XCTAssertEqual(values["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(values["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(PKCE.challenge(for: try XCTUnwrap(values["code_verifier"])), challenge)

        XCTAssertEqual(result.credential.accessToken, "eyJ-access")
        XCTAssertEqual(result.credential.refreshToken, "rt-1")
        XCTAssertEqual(result.credential.accountID, "acct_123")
        XCTAssertEqual(result.credential.expiresAt, fixedNow.addingTimeInterval(3600))
        XCTAssertEqual(result.credential.scopes, ["openid", "profile", "email", "offline_access"])
        XCTAssertEqual(result.email, "codex@example.com")
        XCTAssertEqual(result.planLabel, "plus")

        let released = await AuthTestSupport.eventually { AuthTestSupport.isPortFree(1455) }
        XCTAssertTrue(released)
    }

    func testStateMismatchOnCallbackSendsNothing() async throws {
        try requirePortFree()
        let client = AuthMockHTTPClient(responses: [AuthTestSupport.json(tokenBody(idToken: idToken()))])
        let session = try await makeLogin(client: client).begin(mode: .loopback)
        let completion = Task { try await session.completion(nil) }
        _ = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:1455/auth/callback?code=oa-code&state=forged")!)
        do {
            _ = try await completion.value
            XCTFail("expected stateMismatch")
        } catch LoginError.stateMismatch {
            // expected
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    // MARK: Claim extraction (pure)

    func testResultFallsBackToAccessTokenExpWhenExpiresInMissing() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(tokenBody(idToken: idToken(), accessToken: AuthTestSupport.unsignedJWT(["exp": 1_800_007_200]), expiresIn: nil).utf8)
        ) as? [String: Any])
        let result = try OpenAILogin.result(from: object, now: fixedNow)
        XCTAssertEqual(result.credential.expiresAt, Date(timeIntervalSince1970: 1_800_007_200))
    }

    func testResultStoresIDToken() throws {
        let token = idToken()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tokenBody(idToken: token).utf8)) as? [String: Any])
        let result = try OpenAILogin.result(from: object, now: fixedNow)
        XCTAssertEqual(result.credential.idToken, token, "ISC-81")
    }

    func testMissingAccountIDIsAnError() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(tokenBody(idToken: idToken(accountID: nil)).utf8)
        ) as? [String: Any])
        XCTAssertThrowsError(try OpenAILogin.result(from: object, now: fixedNow)) { error in
            XCTAssertEqual(error as? LoginError, .tokenExchange("no chatgpt_account_id"))
        }
    }

    func testMissingEmailFallsBackToGenericLabel() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(tokenBody(idToken: idToken(email: nil, plan: nil)).utf8)
        ) as? [String: Any])
        let result = try OpenAILogin.result(from: object, now: fixedNow)
        XCTAssertEqual(result.email, "Codex account")
        XCTAssertNil(result.planLabel)
    }
}
