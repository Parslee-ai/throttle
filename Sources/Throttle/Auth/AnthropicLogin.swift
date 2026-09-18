import Foundation

/// Authorization Code + PKCE against Claude's OAuth endpoints (ISC-57–60).
///
/// Two redirect modes: a loopback listener on `localhost:1456` (fallback 1458)
/// and the hosted paste page, where the provider shows `CODE#STATE` and the
/// user pastes it into Throttle. The paste page is the always-available
/// fallback because loopback acceptance for this client is unproven (D-21).
struct AnthropicLogin: OAuthLogin {
    /// The Claude *subscription* authorize page (Claude Code's `CLAUDE_AI_AUTHORIZE_URL`).
    /// The console page at `platform.claude.com/oauth/authorize` is for API
    /// organizations: it grants only `user:profile`, and the usage endpoint then
    /// answers 403 "not allowed for this organization" (ISA D-34).
    static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    /// Primary token endpoint for the code exchange.
    static let tokenURL = AnthropicEndpoints.tokenFallback
    /// Tried once when the primary answers 400 (ISC-59).
    static let tokenRetryURL = AnthropicEndpoints.token
    static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"
    static let loopbackPath = "/callback"
    static let defaultPorts: [UInt16] = [1456, 1458]
    static let scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let fallbackEmail = "Claude account"

    private let client: HTTPClient
    private let provider: AnthropicProvider
    private let preferredPorts: [UInt16]
    private let now: @Sendable () -> Date

    init(
        client: HTTPClient,
        provider: AnthropicProvider,
        preferredPorts: [UInt16] = AnthropicLogin.defaultPorts,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.provider = provider
        self.preferredPorts = preferredPorts
        self.now = now
    }

    func begin(mode: LoginMode) async throws -> LoginSession {
        let pkce = PKCE.generate()
        let state = PKCE.randomState()

        switch mode {
        case .loopback:
            let server = LoopbackCallbackServer(preferredPorts: preferredPorts, path: Self.loopbackPath)
            let port: UInt16
            do {
                port = try await server.start()
            } catch LoopbackError.portsBusy(let ports) {
                throw LoginError.portsBusy(ports)
            }
            let redirectURI = "http://localhost:\(port)\(Self.loopbackPath)"
            let url = Self.authorizeURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state, manual: false)
            return LoginSession(authorizeURL: url, expectsManualCode: false) { _ in
                let code = try await OAuthFlow.awaitLoopbackCode(server: server, expectedState: state)
                return try await complete(code: code, state: state, redirectURI: redirectURI, verifier: pkce.verifier)
            }

        case .manualCode:
            let redirectURI = Self.manualRedirectURI
            let url = Self.authorizeURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state, manual: true)
            return LoginSession(authorizeURL: url, expectsManualCode: true) { pasted in
                let parsed = try Self.parsePastedCode(pasted, fallbackState: state)
                guard parsed.state == state else { throw LoginError.stateMismatch }
                return try await complete(code: parsed.code, state: state, redirectURI: redirectURI, verifier: pkce.verifier)
            }
        }
    }

    // MARK: Authorize

    static func authorizeURL(redirectURI: String, challenge: String, state: String, manual: Bool) -> URL {
        var query: [(String, String)] = []
        if manual {
            query.append(("code", "true"))
        }
        query += [
            ("client_id", AnthropicEndpoints.clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        return OAuthFlow.authorizeURL(base: authorizeURL, query: query)
    }

    /// Splits a pasted `CODE#STATE` value. A value without `#` is taken as the
    /// code alone with our own state. A setup token (`sk-ant-…`) is rejected
    /// outright: the usage endpoint does not accept it (ISC-68).
    static func parsePastedCode(_ pasted: String?, fallbackState: String) throws -> (code: String, state: String) {
        let text = (pasted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LoginError.malformedCode }
        if text.hasPrefix("sk-ant-") {
            throw LoginError.setupTokenNotSupported
        }
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let code = parts[0].trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.allSatisfy({ !$0.isWhitespace }) else { throw LoginError.malformedCode }
        if parts.count == 2 {
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            return (code, state.isEmpty ? fallbackState : state)
        }
        return (code, fallbackState)
    }

    // MARK: Exchange

    private func complete(code: String, state: String, redirectURI: String, verifier: String) async throws -> LoginResult {
        let credential = try await exchange(code: code, state: state, redirectURI: redirectURI, verifier: verifier)
        let profile = try await provider.fetchProfile(credential: credential)
        return LoginResult(
            credential: credential,
            email: profile.email ?? Self.fallbackEmail,
            planLabel: profile.organizationName
        )
    }

    /// The exact fields of the code exchange (ISC-59). `state` is included
    /// because Anthropic requires it on the token request (D-21).
    static func exchangeFields(code: String, state: String, redirectURI: String, verifier: String) -> [(String, String)] {
        [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("state", state),
            ("redirect_uri", redirectURI),
            ("client_id", AnthropicEndpoints.clientID),
            ("code_verifier", verifier),
        ]
    }

    private func exchange(code: String, state: String, redirectURI: String, verifier: String) async throws -> AccountCredential {
        let fields = Self.exchangeFields(code: code, state: state, redirectURI: redirectURI, verifier: verifier)
        var response = try await OAuthFlow.send(
            OAuthFlow.formRequest(url: Self.tokenURL, fields: fields, userAgent: AnthropicEndpoints.userAgent),
            via: client
        )
        if response.statusCode == 400 {
            response = try await OAuthFlow.send(
                OAuthFlow.formRequest(url: Self.tokenRetryURL, fields: fields, userAgent: AnthropicEndpoints.userAgent),
                via: client
            )
        }
        return try Self.credential(from: try OAuthFlow.tokenObject(from: response), now: now())
    }

    /// Maps a token response onto a credential (ISC-61). `refresh_token_expires_in`
    /// is stored as `refreshTokenExpiresAt` when present; the refresh doctrine
    /// still handles an expired refresh token by flipping the account to
    /// needs-login rather than acting on the date.
    static func credential(from object: [String: Any], now: Date) throws -> AccountCredential {
        guard let accessToken = OAuthFlow.string(object, "access_token") else {
            throw LoginError.tokenExchange("the token response had no access_token")
        }
        let scopes = OAuthFlow.string(object, "scope")?
            .split(separator: " ").map(String.init) ?? [scope]
        return AccountCredential(
            accessToken: accessToken,
            refreshToken: OAuthFlow.string(object, "refresh_token"),
            expiresAt: OAuthFlow.seconds(object, "expires_in").map { now.addingTimeInterval($0) },
            accountID: nil,
            scopes: scopes,
            refreshTokenExpiresAt: OAuthFlow.seconds(object, "refresh_token_expires_in").map { now.addingTimeInterval($0) }
        )
    }
}
