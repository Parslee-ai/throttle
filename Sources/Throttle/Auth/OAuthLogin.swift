import Foundation

/// How the provider hands the authorization code back to Throttle.
enum LoginMode: Sendable, Equatable {
    /// A loopback HTTP listener on `127.0.0.1` receives the browser redirect.
    case loopback
    /// The provider shows the code on a hosted page and the user pastes it.
    case manualCode
}

/// What a completed login yields: the credential to store plus the labels
/// the account row shows.
struct LoginResult: Sendable {
    let credential: AccountCredential
    let email: String
    let planLabel: String?
}

/// One login in progress. The UI opens `authorizeURL` in the default browser
/// (`NSWorkspace.shared.open`, ISC-58) and then awaits `completion`: with
/// `nil` to wait for the loopback callback, or with the string the user
/// pasted when `expectsManualCode` is true. Cancelling the task that awaits
/// `completion` tears the loopback listener down.
struct LoginSession: Sendable {
    let authorizeURL: URL
    let expectsManualCode: Bool
    let completion: @Sendable (String?) async throws -> LoginResult
}

/// Everything that can go wrong between "Add account" and a stored credential.
/// Every case carries a user-facing description that is safe to show as-is.
enum LoginError: Error, Equatable, Sendable, LocalizedError {
    /// The `state` on the callback did not match the one we sent (ISC-60).
    case stateMismatch
    /// None of the loopback ports could be bound (ISC-80).
    case portsBusy([UInt16])
    /// The provider redirected back with an `error` instead of a code.
    case providerDenied(String)
    /// No callback arrived before the deadline.
    case timeout
    /// The pasted value was empty or not shaped like a code.
    case malformedCode
    /// The token endpoint refused the code. The string is a short, redacted reason.
    case tokenExchange(String)
    /// A `claude setup-token` value was pasted; only a full login works (ISC-68).
    case setupTokenNotSupported

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "The sign-in response did not match this login attempt, so nothing was saved. Please try again."
        case .portsBusy(let ports):
            let list = ports.map(String.init).joined(separator: ", ")
            if ports == [OpenAILogin.callbackPort] {
                return "Port \(list) is already in use, so the browser cannot hand the sign-in back to Throttle. "
                    + "If a Codex CLI login is in progress, finish or cancel it, then try again."
            }
            let noun = ports.count == 1 ? "Port \(list) is" : "Ports \(list) are"
            return "\(noun) already in use, so the browser cannot hand the sign-in back to Throttle. "
                + "Close the app using the port, or choose the paste-the-code option."
        case .providerDenied(let reason):
            return "The provider did not complete the sign-in: \(reason)"
        case .timeout:
            return "Timed out waiting for the browser to finish signing in."
        case .malformedCode:
            return "That does not look like a sign-in code. Paste the whole value the provider showed you."
        case .tokenExchange(let reason):
            return "The provider rejected the sign-in code: \(reason)"
        case .setupTokenNotSupported:
            return "That is a setup token, not a login. Throttle needs a full sign-in with the browser, "
                + "because the usage endpoint rejects setup tokens."
        }
    }
}

/// A provider-specific OAuth login. Both conformers run the same shape:
/// `begin` prepares PKCE, state, and the redirect leg, and hands back a
/// session whose completion finishes the exchange.
protocol OAuthLogin: Sendable {
    func begin(mode: LoginMode) async throws -> LoginSession
}

/// The steps both providers share: building the authorize URL, running the
/// loopback leg with state verification, encoding the token request, and
/// reading the token response without ever echoing a token into an error.
enum OAuthFlow {
    /// How long the loopback listener waits for the browser.
    static let callbackTimeout: TimeInterval = 300

    /// `base` with `query` appended in order. Values are percent-encoded by
    /// `URLComponents`, so a space in `scope` becomes `%20`.
    static func authorizeURL(base: URL, query: [(String, String)]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// Waits on the loopback listener and verifies the returned `state`
    /// (ISC-60). The listener is stopped on every path out of here.
    static func awaitLoopbackCode(server: LoopbackCallbackServer, expectedState: String) async throws -> String {
        let callback: LoopbackCallback
        do {
            callback = try await server.waitForCode(timeout: callbackTimeout)
        } catch {
            await server.stop()
            throw error
        }
        guard callback.state == expectedState else {
            await server.stop()
            throw LoginError.stateMismatch
        }
        return callback.code
    }

    /// An `application/x-www-form-urlencoded` POST.
    static func formRequest(url: URL, fields: [(String, String)], userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formBody(fields).utf8)
        return request
    }

    static func formBody(_ fields: [(String, String)]) -> String {
        fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The token response as a JSON object, or a `tokenExchange` error.
    static func tokenObject(from response: HTTPResponse) throws -> [String: Any] {
        guard response.statusCode == 200 else {
            throw LoginError.tokenExchange(failureReason(response))
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body),
              let object = json as? [String: Any] else {
            throw LoginError.tokenExchange("the token response was not a JSON object")
        }
        return object
    }

    /// `"HTTP 400 (invalid_grant)"`-style reason with anything token-shaped
    /// removed, so the message can go straight to the screen.
    static func failureReason(_ response: HTTPResponse) -> String {
        var reason = "HTTP \(response.statusCode)"
        if let json = try? JSONSerialization.jsonObject(with: response.body),
           let object = json as? [String: Any] {
            let code = object["error"] as? String
                ?? (object["error"] as? [String: Any])?["type"] as? String
            let detail = object["error_description"] as? String
                ?? (object["error"] as? [String: Any])?["message"] as? String
            let text = [code, detail].compactMap { $0 }.joined(separator: ": ")
            if !text.isEmpty {
                reason += " (\(text.prefix(200)))"
            }
        }
        return Redactor.redact(reason)
    }

    /// A non-empty string field of a token object.
    static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A numeric field that may arrive as a number or a numeric string.
    static func seconds(_ object: [String: Any], _ key: String) -> TimeInterval? {
        if let number = object[key] as? NSNumber { return number.doubleValue }
        if let text = object[key] as? String { return Double(text) }
        return nil
    }

    /// Sends and rewraps transport errors so a description can never carry
    /// the request that failed.
    static func send(_ request: URLRequest, via client: HTTPClient) async throws -> HTTPResponse {
        do {
            return try await client.send(request)
        } catch UsageError.transport(let underlying) {
            throw LoginError.tokenExchange(Redactor.redact("network error: \(underlying.localizedDescription)"))
        } catch let error as UsageError {
            throw LoginError.tokenExchange(Redactor.redact(String(describing: error)))
        }
    }
}
