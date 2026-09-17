import Foundation

/// Reads Codex subscription usage for one ChatGPT account.
///
/// The adapter touches exactly two URLs: the usage summary and the OAuth token
/// endpoint. It never issues a request that spends quota or credits.
struct OpenAIProvider: UsageProvider {
    let provider: Provider = .openai

    private let client: HTTPClient
    private let now: @Sendable () -> Date

    /// Usage payloads are a few kilobytes; anything past this is not a payload.
    static let maxUsageBodyBytes = 256 * 1024

    init(client: HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        try await fetchDetailed(account: account, credential: credential).status
    }

    /// Like `fetchStatus`, but also returns what the shared status type cannot
    /// carry: the plan badge and the per-model lanes.
    func fetchDetailed(
        account: Account,
        credential: AccountCredential
    ) async throws -> (status: AccountStatus, snapshot: OpenAIUsageSnapshot) {
        var request = URLRequest(url: OpenAIEndpoints.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await client.send(request, maxBodyBytes: Self.maxUsageBodyBytes)
        let fetchedAt = now()

        let snapshot: OpenAIUsageSnapshot
        switch response.statusCode {
        case 200:
            snapshot = try OpenAIUsageParser.parse(response.body, now: fetchedAt)
        case 401:
            throw UsageError.needsLogin
        case 403:
            // A hard limit comes back as 403 with the normal usage body; the
            // account is fine, it is just out of quota. Anything else is auth.
            guard let parsed = try? OpenAIUsageParser.parse(response.body, now: fetchedAt) else {
                throw UsageError.needsLogin
            }
            snapshot = parsed
        case 429:
            throw UsageError.rateLimited(retryAfter: Self.retryAfter(from: response))
        case 300...399:
            throw UsageError.redirect
        default:
            throw UsageError.invalidResponse("HTTP \(response.statusCode)")
        }

        let status = AccountStatus(
            accountID: account.id,
            provider: .openai,
            email: snapshot.email ?? account.email,
            windows: snapshot.windows + snapshot.additionalWindows,
            fetchedAt: fetchedAt,
            state: .ok
        )
        return (status, snapshot)
    }

    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw UsageError.needsLogin
        }

        var request = URLRequest(url: OpenAIEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.refreshFormBody(refreshToken: refreshToken).utf8)

        let response = try await client.send(request, maxBodyBytes: Self.maxUsageBodyBytes)

        switch response.statusCode {
        case 200:
            break
        case 400, 401:
            throw UsageError.needsLogin
        case 429:
            throw UsageError.rateLimited(retryAfter: Self.retryAfter(from: response))
        case 300...399:
            throw UsageError.redirect
        default:
            throw UsageError.invalidResponse("HTTP \(response.statusCode)")
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw UsageError.invalidResponse("unparseable token response")
        }
        if token.error == "invalid_grant" {
            throw UsageError.needsLogin
        }
        guard let accessToken = token.accessToken, !accessToken.isEmpty else {
            throw UsageError.invalidResponse("token response without access_token")
        }

        let idClaims = token.idToken.flatMap(JWTClaims.decode)
        let accessClaims = JWTClaims.decode(accessToken)

        var expiresAt: Date?
        if let expiresIn = token.expiresIn {
            expiresAt = now().addingTimeInterval(expiresIn)
        } else {
            expiresAt = accessClaims?.exp
        }

        return AccountCredential(
            accessToken: accessToken,
            refreshToken: token.refreshToken ?? credential.refreshToken,
            expiresAt: expiresAt,
            accountID: idClaims?.chatgptAccountID ?? accessClaims?.chatgptAccountID ?? credential.accountID,
            scopes: credential.scopes.isEmpty ? OpenAIEndpoints.scopes : credential.scopes
        )
    }

    // MARK: - Helpers

    /// The exact form body sent to the token endpoint on refresh.
    static func refreshFormBody(refreshToken: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        let scope = OpenAIEndpoints.scopes.joined(separator: "%20")
        return "grant_type=refresh_token"
            + "&refresh_token=\(encodedToken)"
            + "&client_id=\(OpenAIEndpoints.clientID)"
            + "&scope=\(scope)"
    }

    private static func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        return nil
    }

    private struct TokenResponse: Decodable {
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: TimeInterval?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case error
        }
    }
}
