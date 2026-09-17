import Foundation

/// Authorization Code + PKCE against OpenAI's OAuth endpoints (ISC-78–82).
///
/// The redirect `http://localhost:1455/auth/callback` is the one registered
/// for the Codex client id, so the loopback listener must take port 1455 and
/// there is no paste-the-code alternative (D-21). When the port is held, most
/// likely by a Codex CLI login in progress, the login fails with a message
/// that names the port (ISC-80) instead of hanging.
struct OpenAILogin: OAuthLogin {
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let redirectURI = "http://localhost:\(callbackPort)\(callbackPath)"
    static let fallbackEmail = "Codex account"

    private let client: HTTPClient
    private let provider: OpenAIProvider
    private let now: @Sendable () -> Date

    init(client: HTTPClient, provider: OpenAIProvider, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.provider = provider
        self.now = now
    }

    /// `mode` is accepted for protocol symmetry; OpenAI has no manual-code
    /// page, so every session is a loopback session.
    func begin(mode: LoginMode) async throws -> LoginSession {
        let pkce = PKCE.generate()
        let state = PKCE.randomState()

        let server = LoopbackCallbackServer(preferredPorts: [Self.callbackPort], path: Self.callbackPath)
        do {
            try await server.start()
        } catch LoopbackError.portsBusy(let ports) {
            throw LoginError.portsBusy(ports)
        }

        let url = Self.authorizeURL(challenge: pkce.challenge, state: state)
        return LoginSession(authorizeURL: url, expectsManualCode: false) { _ in
            let code = try await OAuthFlow.awaitLoopbackCode(server: server, expectedState: state)
            return try await complete(code: code, verifier: pkce.verifier)
        }
    }

    // MARK: Authorize

    static func authorizeURL(challenge: String, state: String) -> URL {
        OAuthFlow.authorizeURL(base: OpenAIEndpoints.authorizeURL, query: [
            ("response_type", "code"),
            ("client_id", OpenAIEndpoints.clientID),
            ("redirect_uri", redirectURI),
            ("scope", OpenAIEndpoints.scopes.joined(separator: " ")),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
        ])
    }

    // MARK: Exchange

    /// The exact fields of the code exchange (ISC-81).
    static func exchangeFields(code: String, verifier: String) -> [(String, String)] {
        [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", OpenAIEndpoints.clientID),
            ("code_verifier", verifier),
        ]
    }

    private func complete(code: String, verifier: String) async throws -> LoginResult {
        let request = OAuthFlow.formRequest(
            url: OpenAIEndpoints.tokenURL,
            fields: Self.exchangeFields(code: code, verifier: verifier),
            userAgent: OpenAIEndpoints.userAgent
        )
        let response = try await OAuthFlow.send(request, via: client)
        return try Self.result(from: try OAuthFlow.tokenObject(from: response), now: now())
    }

    /// Reads the tokens and the `id_token` claims (ISC-82): `chatgpt_account_id`
    /// becomes the credential's account id and is required, `email` labels
    /// the account, `chatgpt_plan_type` becomes the plan badge.
    static func result(from object: [String: Any], now: Date) throws -> LoginResult {
        guard let accessToken = OAuthFlow.string(object, "access_token") else {
            throw LoginError.tokenExchange("the token response had no access_token")
        }
        let idClaims = OAuthFlow.string(object, "id_token").flatMap(JWTClaims.decode)
        let accessClaims = JWTClaims.decode(accessToken)

        guard let accountID = idClaims?.chatgptAccountID ?? accessClaims?.chatgptAccountID,
              !accountID.isEmpty else {
            throw LoginError.tokenExchange("no chatgpt_account_id")
        }

        let expiresAt: Date?
        if let seconds = OAuthFlow.seconds(object, "expires_in") {
            expiresAt = now.addingTimeInterval(seconds)
        } else {
            expiresAt = accessClaims?.exp ?? idClaims?.exp
        }

        let credential = AccountCredential(
            accessToken: accessToken,
            refreshToken: OAuthFlow.string(object, "refresh_token"),
            expiresAt: expiresAt,
            accountID: accountID,
            scopes: OpenAIEndpoints.scopes
        )
        return LoginResult(
            credential: credential,
            email: idClaims?.email ?? accessClaims?.email ?? fallbackEmail,
            planLabel: idClaims?.chatgptPlanType ?? accessClaims?.chatgptPlanType
        )
    }
}
