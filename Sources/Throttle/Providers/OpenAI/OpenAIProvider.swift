import Foundation

/// Reads Codex subscription usage for one ChatGPT account.
///
/// The adapter touches three URLs: the usage summary, the OAuth token endpoint,
/// and the reset consume endpoint. The usage read never spends quota or
/// credits. The one spending call is `useReset`, which posts to
/// `OpenAIEndpoints.resetConsumeURL` only on an explicit, confirmed user action.
struct OpenAIProvider: UsageProvider {
    let provider: Provider = .openai

    private let client: HTTPClient
    private let now: @Sendable () -> Date
    /// Receives one line per non-200 response, with the bearer header removed.
    private let diagnostics: Diagnostics?

    /// Usage payloads are a few kilobytes; anything past this is not a payload.
    static let maxUsageBodyBytes = 256 * 1024
    /// A reset answer is a code and a count; anything past this is not one.
    static let maxResetBodyBytes = 64 * 1024

    init(
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: Diagnostics? = nil
    ) {
        self.client = client
        self.now = now
        self.diagnostics = diagnostics
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
        if response.statusCode != 200 {
            await diagnose(.usage, accountID: account.id, request: request, response: response, at: fetchedAt)
        }

        let snapshot: OpenAIUsageSnapshot
        switch response.statusCode {
        case 200:
            snapshot = try OpenAIUsageParser.parse(response.body, now: fetchedAt)
        case 401:
            throw UsageError.needsLogin
        case 403:
            // A hard limit comes back as 403 with the normal usage body; the
            // account is fine, it is just out of quota. A JSON error whose
            // type says permission or forbidden is the organization refusing
            // this client (D-33). Anything else is auth.
            guard let parsed = try? OpenAIUsageParser.parse(response.body, now: fetchedAt) else {
                if let message = Self.permissionRefusal(in: response.body) {
                    throw UsageError.forbidden(reason: message)
                }
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
            state: .ok,
            planLabel: snapshot.planType.flatMap { $0.isEmpty ? nil : $0 },
            resetCreditsAvailable: snapshot.resetCreditsAvailable
        )
        return (status, snapshot)
    }

    /// Spends one banked rate-limit reset.
    ///
    /// Sends exactly one request and never refreshes or retries on its own: a
    /// 401 is thrown as `needsLogin`, and the caller owns refresh-and-resend
    /// with the same `attemptID`. The attempt id goes out as
    /// `redeem_request_id`, so a resend of an attempt that already went
    /// through answers `already_redeemed` instead of spending a second reset.
    /// No `credit_id` is sent, so the provider picks the credit.
    func useReset(account: Account, credential: AccountCredential, attemptID: UUID) async throws -> ResetOutcome {
        var request = URLRequest(url: OpenAIEndpoints.resetConsumeURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.resetRequestBody(attemptID: attemptID)

        let response = try await client.send(request, maxBodyBytes: Self.maxResetBodyBytes)
        if response.statusCode != 200 {
            await diagnose(.reset, accountID: account.id, request: request, response: response, at: now())
        }

        switch response.statusCode {
        case 200...299:
            return Self.resetOutcome(for: OpenAIResetAnswer.parse(response.body))
        case 401:
            throw UsageError.needsLogin
        case 403:
            if let message = Self.permissionRefusal(in: response.body) {
                throw UsageError.forbidden(reason: message)
            }
            throw UsageError.needsLogin
        case 429:
            throw UsageError.rateLimited(retryAfter: Self.retryAfter(from: response))
        case 300...399:
            throw UsageError.redirect
        default:
            throw UsageError.httpStatus(response.statusCode)
        }
    }

    /// The exact JSON body sent to the consume endpoint.
    static func resetRequestBody(attemptID: UUID) -> Data {
        // Two string keys: serialization cannot fail.
        (try? JSONSerialization.data(
            withJSONObject: ["redeem_request_id": attemptID.uuidString.lowercased()],
            options: [.sortedKeys]
        )) ?? Data()
    }

    /// Maps the provider's answer code onto the provider-neutral outcome.
    /// `already_redeemed` means this same attempt was spent earlier, which is
    /// success. An unknown code or an unreadable body is never success.
    static func resetOutcome(for answer: OpenAIResetAnswer?) -> ResetOutcome {
        switch answer?.code {
        case "reset", "already_redeemed":
            return .reset
        case "nothing_to_reset":
            return .nothingToReset
        case "no_credit":
            return .noCredit
        default:
            return .unexpected
        }
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
        if response.statusCode != 200 {
            await diagnose(.refresh, accountID: nil, request: request, response: response, at: now())
        }

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
            scopes: credential.scopes.isEmpty ? OpenAIEndpoints.scopes : credential.scopes,
            refreshTokenExpiresAt: credential.refreshTokenExpiresAt,
            idToken: token.idToken ?? credential.idToken
        )
    }

    // MARK: - Helpers

    /// One diagnostics line for a non-200 exchange. `DiagnosticEvent` drops
    /// the bearer header and redacts the body before anything is written.
    private func diagnose(
        _ kind: DiagnosticEvent.Kind,
        accountID: UUID?,
        request: URLRequest,
        response: HTTPResponse,
        at: Date
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(DiagnosticEvent(
            ts: at,
            provider: .openai,
            accountID: accountID,
            kind: kind,
            request: request,
            response: response,
            retryAfter: Self.retryAfter(from: response)
        ))
    }

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

    /// The message from a 403 body that is a JSON error of a permission or
    /// forbidden type (`{"error":{"type":"…","message":"…"}}` or the flat
    /// `{"error":"…","error_description":"…"}` form), already redacted.
    /// `nil` for anything else, so an unknown 403 still reads as needs-login.
    static func permissionRefusal(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let root = json as? [String: Any] else {
            return nil
        }
        let type: String
        var message: String?
        if let error = root["error"] as? [String: Any] {
            type = ((error["type"] as? String) ?? (error["code"] as? String) ?? "").lowercased()
            message = error["message"] as? String
        } else if let error = root["error"] as? String {
            type = error.lowercased()
            message = (root["error_description"] as? String) ?? (root["message"] as? String)
        } else {
            return nil
        }
        guard type.contains("permission") || type.contains("forbidden") else { return nil }
        var text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = "Not allowed by organization (\(type))" }
        return Redactor.redact(String(text.prefix(300)))
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
