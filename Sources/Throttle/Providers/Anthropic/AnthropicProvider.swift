import Foundation

/// Reads Claude subscription usage through the OAuth usage endpoint.
///
/// Read-only by construction: the only URLs this type knows are the usage,
/// profile, and token endpoints in `AnthropicEndpoints`. It never calls a
/// messages or completions endpoint, so a poll can never spend quota.
struct AnthropicProvider: UsageProvider {
    let provider: Provider = .anthropic

    private let client: HTTPClient
    private let now: @Sendable () -> Date

    init(client: HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    // MARK: - Usage

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        let request = authorizedRequest(url: AnthropicEndpoints.usage, accessToken: credential.accessToken)
        let response = try await send(request)

        switch response.statusCode {
        case 200:
            let windows = try AnthropicUsageParser.parse(response.body)
            return AccountStatus(
                accountID: account.id,
                provider: .anthropic,
                email: account.email,
                windows: windows,
                fetchedAt: now(),
                state: .ok
            )
        case 401, 403:
            throw UsageError.needsLogin
        case 429:
            throw UsageError.rateLimited(retryAfter: retryAfter(from: response))
        case 300...399:
            throw UsageError.redirect
        default:
            throw UsageError.invalidResponse("HTTP \(response.statusCode)")
        }
    }

    // MARK: - Profile

    /// Best-effort read of the account's email and organization name, used once
    /// after login to label the account. Any non-200 yields nils; only a
    /// transport failure throws.
    func fetchProfile(credential: AccountCredential) async throws -> (email: String?, organizationName: String?) {
        let request = authorizedRequest(url: AnthropicEndpoints.profile, accessToken: credential.accessToken)
        let response = try await send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body),
              let root = json as? [String: Any] else {
            return (nil, nil)
        }

        var email: String?
        if let account = root["account"] as? [String: Any] {
            email = nonEmpty(account["email"] as? String)
        }
        if email == nil {
            email = nonEmpty(root["email"] as? String)
        }

        var organizationName: String?
        if let organization = root["organization"] as? [String: Any] {
            organizationName = nonEmpty(organization["name"] as? String)
        }
        return (email, organizationName)
    }

    // MARK: - Refresh

    /// Rotates the credential. Tries the console endpoint with a JSON body, and
    /// on a plain HTTP 400 retries once form-encoded against the platform
    /// endpoint. Contains no cancellation checks on purpose: a rotation that is
    /// abandoned halfway invalidates the refresh token (see `UsageProvider`).
    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw UsageError.needsLogin
        }

        var response = try await send(jsonTokenRequest(refreshToken: refreshToken))
        if isInvalidGrant(response) {
            throw UsageError.needsLogin
        }
        if response.statusCode == 400 {
            response = try await send(formTokenRequest(refreshToken: refreshToken))
            if isInvalidGrant(response) {
                throw UsageError.needsLogin
            }
        }

        switch response.statusCode {
        case 200:
            return try rotatedCredential(from: response.body, previous: credential)
        case 401:
            throw UsageError.needsLogin
        default:
            throw UsageError.invalidResponse("HTTP \(response.statusCode)")
        }
    }

    private func jsonTokenRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: AnthropicEndpoints.token)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AnthropicEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": AnthropicEndpoints.clientID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func formTokenRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: AnthropicEndpoints.tokenFallback)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AnthropicEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        let fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", AnthropicEndpoints.clientID),
        ]
        let encoded = fields
            .map { "\($0.0)=\(formEncode($0.1))" }
            .joined(separator: "&")
        request.httpBody = Data(encoded.utf8)
        return request
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func isInvalidGrant(_ response: HTTPResponse) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: response.body),
              let root = json as? [String: Any] else {
            // Fall back to a textual match for non-JSON error pages.
            return String(decoding: response.body, as: UTF8.self).contains("invalid_grant")
        }
        if let error = root["error"] as? String, error == "invalid_grant" { return true }
        if let error = root["error"] as? [String: Any],
           let type = error["type"] as? String, type == "invalid_grant" { return true }
        return false
    }

    private func rotatedCredential(from body: Data, previous: AccountCredential) throws -> AccountCredential {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let root = json as? [String: Any] else {
            throw UsageError.invalidResponse("token response is not an object")
        }
        guard let accessToken = nonEmpty(root["access_token"] as? String) else {
            throw UsageError.invalidResponse("token response lacks access_token")
        }

        var expiresAt: Date?
        if let seconds = root["expires_in"] as? NSNumber {
            expiresAt = now().addingTimeInterval(seconds.doubleValue)
        } else if let text = root["expires_in"] as? String, let seconds = Double(text) {
            expiresAt = now().addingTimeInterval(seconds)
        }

        var scopes = previous.scopes
        if let scope = nonEmpty(root["scope"] as? String) {
            scopes = scope.split(separator: " ").map(String.init)
        }

        return AccountCredential(
            accessToken: accessToken,
            refreshToken: nonEmpty(root["refresh_token"] as? String) ?? previous.refreshToken,
            expiresAt: expiresAt,
            accountID: previous.accountID,
            scopes: scopes
        )
    }

    // MARK: - Plumbing

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AnthropicEndpoints.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(AnthropicEndpoints.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AnthropicEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Sends through the client and rewraps transport failures so that
    /// describing the error can never echo the request's bearer token.
    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            return try await client.send(request, maxBodyBytes: AnthropicEndpoints.maxBodyBytes)
        } catch UsageError.transport(let underlying) {
            throw UsageError.transport(RedactedTransportError(underlying))
        }
    }

    /// Parses `Retry-After` as integer seconds or an HTTP-date. Returns `nil`
    /// when the header is absent or unreadable so the scheduler applies its
    /// own default.
    private func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSince(now()))
            }
        }
        return nil
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// Wraps a URL loading error so that any rendering of it passes through
/// `Redactor`. `URLError` descriptions can include the failing request, and a
/// request carries the bearer header.
private struct RedactedTransportError: Error, CustomStringConvertible, CustomDebugStringConvertible {
    let underlying: Error

    init(_ underlying: Error) {
        self.underlying = underlying
    }

    var description: String {
        Redactor.redact(String(describing: underlying))
    }

    var debugDescription: String {
        Redactor.redact(String(reflecting: underlying))
    }

    var localizedDescription: String {
        Redactor.redact(underlying.localizedDescription)
    }
}
