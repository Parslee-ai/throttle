import Foundation
import OSLog

/// Reads Claude subscription usage through the OAuth usage endpoint, and
/// spends a banked limit reset when the user asks for one.
///
/// The usage read never spends: `fetchStatus` only calls the usage, profile,
/// and token endpoints in `AnthropicEndpoints`, and this type knows no
/// messages or completions endpoint, so a poll can never spend quota. The one
/// spending call is `useReset`, sent only on an explicit, confirmed user
/// action and never from a poll.
struct AnthropicProvider: UsageProvider {
    let provider: Provider = .anthropic

    private let client: HTTPClient
    private let now: @Sendable () -> Date
    /// Receives one line per non-200 response, with the bearer header removed.
    private let diagnostics: Diagnostics?
    /// Plans and organization ids read from the profile this launch. Shared
    /// by every copy of this provider, so the profile is read at most once
    /// per account per launch.
    private let plans = ProfilePlanCache()
    /// The grant each account's last usage read would spend, in memory only.
    private let grants = ResetGrantCache()
    /// Longest the one-time plan read may add to a usage read. It is also
    /// capped by what is left of the scheduler's budget for the fetch
    /// (`FetchBudget`), less `profileMargin`, so a slow profile can never turn
    /// a good usage reading into a timeout; past that it is abandoned and
    /// tried again on a later poll.
    private let profileBudget: TimeInterval
    /// Time kept in hand at the end of the scheduler's budget.
    static let profileMargin: TimeInterval = 0.5
    /// How long a refused profile read waits when the answer names no
    /// `Retry-After`.
    static let profileRefusalHold: TimeInterval = 3600

    /// The wait after a refused profile read: the answer's `Retry-After`,
    /// kept within 0…60 minutes like every other backoff, or an hour when the
    /// value is missing or not a finite number.
    static func profileHold(retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter, retryAfter.isFinite else { return profileRefusalHold }
        return min(max(retryAfter, 0), profileRefusalHold)
    }

    init(
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: Diagnostics? = nil,
        profileBudget: TimeInterval = 4
    ) {
        self.client = client
        self.now = now
        self.diagnostics = diagnostics
        self.profileBudget = profileBudget
    }

    // MARK: - Usage

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        // A token from the API-console login carries only `user:profile`; the
        // usage endpoint refuses it and repeated refusals earn a 429 (D-34).
        // Do not spend a request on it: the row needs a subscription login.
        if Self.isConsoleToken(credential) {
            throw UsageError.needsLogin
        }
        let body = try await readUsage(accountID: account.id, credential: credential)
        let windows = try AnthropicUsageParser.parse(body)
        let resets = AnthropicResetParser.parse(body)
        await grants.remember(resets.selectedGrantID, for: account.id)
        let fetchedAt = now()
        return AccountStatus(
            accountID: account.id,
            provider: .anthropic,
            email: account.email,
            windows: windows,
            fetchedAt: fetchedAt,
            state: .ok,
            planLabel: await planLabel(for: account, credential: credential),
            resetCreditsAvailable: resets.count
        )
    }

    /// One usage request. The body on a 200; every other answer is thrown as
    /// the `UsageError` the scheduler maps onto the row.
    private func readUsage(accountID: UUID, credential: AccountCredential) async throws -> Data {
        let request = authorizedRequest(url: AnthropicEndpoints.usage, accessToken: credential.accessToken)
        let response = try await send(request)
        if response.statusCode != 200 {
            await diagnose(.usage, accountID: accountID, request: request, response: response, retryAfter: retryAfter(from: response))
        }

        switch response.statusCode {
        case 200:
            return response.body
        case 401:
            Self.logger.error("Usage rejected with HTTP 401: \(Self.snippet(response.body), privacy: .public)")
            throw UsageError.needsLogin
        case 403:
            // A permission error is the organization refusing this client
            // ("OAuth authentication is currently not allowed for this
            // organization"). Logging in again cannot change that, and
            // repeating the request earns a 429 (D-33). Any other 403 is
            // treated as an auth problem, as before.
            if let message = Self.permissionRefusal(in: response.body) {
                Self.logger.error("Usage forbidden for this organization: \(message, privacy: .public)")
                throw UsageError.forbidden(reason: message)
            }
            Self.logger.error("Usage rejected with HTTP 403: \(Self.snippet(response.body), privacy: .public)")
            throw UsageError.needsLogin
        case 429:
            let retry = retryAfter(from: response)
            Self.logger.error("Usage rate limited; Retry-After \(retry.map { String(Int($0)) } ?? "absent", privacy: .public)s")
            throw UsageError.rateLimited(retryAfter: retry)
        case 300...399:
            throw UsageError.redirect
        default:
            throw UsageError.invalidResponse("HTTP \(response.statusCode)")
        }
    }

    private static let logger = Logger(subsystem: "ai.parslee.throttle", category: "AnthropicProvider")

    /// True when the credential was minted by the console authorize page:
    /// it names scopes and none of them is `user:inference`. A credential with
    /// no recorded scopes (an import) is given the benefit of the doubt.
    static func isConsoleToken(_ credential: AccountCredential) -> Bool {
        !credential.scopes.isEmpty && !credential.scopes.contains("user:inference")
    }

    /// The provider's message when a 403 body is a permission error, already
    /// redacted, or `nil` when the body is anything else (not JSON, no
    /// `error` object, or a different error type). The shape is
    /// `{"type":"error","error":{"type":"permission_error","message":"…",
    /// "details":{"error_code":"oauth_not_allowed_for_organization"}}}`; a
    /// `details.error_code` counts even if the type name changes.
    static func permissionRefusal(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let root = json as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        let type = (error["type"] as? String) ?? ""
        let details = error["details"] as? [String: Any]
        let code = details?["error_code"] as? String
        guard type == "permission_error" || code != nil else { return nil }
        var message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if message.isEmpty {
            message = code.map { "Not allowed by organization (\($0))" } ?? "Not allowed by organization"
        }
        return Redactor.redact(String(message.prefix(300)))
    }

    /// The first 300 bytes of an error body, redacted, for the log. The body
    /// is the provider's error object, never a token, but it is redacted and
    /// capped all the same.
    private static func snippet(_ body: Data) -> String {
        Redactor.redact(String(decoding: body.prefix(300), as: UTF8.self))
    }

    // MARK: - Profile

    /// What one profile request produced.
    private enum ProfileAnswer: Sendable {
        /// A 200 with a readable body.
        case read(AnthropicProfile)
        /// Any other answer: a non-200, or a body that is not a JSON object.
        /// `retryAfter` is the response's `Retry-After`, when it has one.
        case refused(retryAfter: TimeInterval?)
    }

    /// Best-effort read of the account's email and plan. `nil` for any
    /// non-200 or a body that is not a JSON object; only a transport failure
    /// throws.
    func fetchProfile(credential: AccountCredential, accountID: UUID? = nil) async throws -> AnthropicProfile? {
        if case .read(let profile) = try await requestProfile(credential: credential, accountID: accountID) {
            return profile
        }
        return nil
    }

    private func requestProfile(credential: AccountCredential, accountID: UUID?) async throws -> ProfileAnswer {
        let request = authorizedRequest(url: AnthropicEndpoints.profile, accessToken: credential.accessToken)
        let response = try await send(request)
        guard response.statusCode == 200 else {
            let retry = retryAfter(from: response)
            await diagnose(.profile, accountID: accountID, request: request, response: response, retryAfter: retry)
            return .refused(retryAfter: retry)
        }
        guard let profile = AnthropicProfileParser.parse(response.body) else {
            return .refused(retryAfter: nil)
        }
        return .read(profile)
    }

    /// Forgets the plan, the organization id, any wait, and the reset grant
    /// for this account, so the next poll reads them again with the new
    /// sign-in and a reset goes to the new sign-in's organization.
    ///
    /// The grant pinned to the latest reset attempt is kept. The app keeps an
    /// unconfirmed attempt's id across a sign-in, and that attempt may have
    /// already spent its grant; sending the same id to a freshly selected
    /// grant could spend a second one. `useReset` drops the pin only once it
    /// knows the new sign-in belongs to a different organization.
    func accountDidSignIn(_ accountID: UUID) async {
        await plans.forget(accountID)
        await grants.forgetSelection(accountID)
    }

    /// The account's plan, read from the profile once per launch with the
    /// credential this usage fetch already resolved. Never throws and never
    /// changes the usage reading, its state, or the scheduler's backoff:
    ///
    /// - A successful read is kept for the rest of the launch, even when the
    ///   profile names no plan.
    /// - A refused read (a 429, a 5xx, any other non-200, or an unreadable
    ///   body) is not retried until its `Retry-After`, or for an hour when it
    ///   names none, so a refusing endpoint is not asked again every poll.
    /// - A transport failure, or a read that runs out of time, is retried on
    ///   the next poll. Nothing reached the provider's answer, no diagnostics
    ///   line is written, the read is bounded by the time budget, and polls
    ///   are at least a minute apart.
    private func planLabel(for account: Account, credential: AccountCredential) async -> String? {
        if let known = await plans.known(for: account.id) {
            return known.plan
        }
        let started = now()
        if await plans.isHeld(account.id, at: started) {
            return nil
        }
        var budget = profileBudget
        if let remaining = FetchBudget.remaining {
            budget = min(budget, remaining() - Self.profileMargin)
        }
        guard budget > 0 else { return nil }

        switch await boundedProfileRead(credential: credential, accountID: account.id, budget: budget) {
        case .answered(.read(let profile)):
            await plans.remember(profile, for: account.id)
            return profile.planLabel
        case .answered(.refused(let retryAfter)):
            await plans.hold(account.id, until: started.addingTimeInterval(Self.profileHold(retryAfter: retryAfter)))
            return nil
        case .failed, .outOfTime:
            return nil
        }
    }

    private enum ProfileRead: Sendable {
        case answered(ProfileAnswer)
        case failed
        case outOfTime
    }

    /// One profile request, raced against `budget` seconds. The request is
    /// cancelled when the budget runs out first.
    private func boundedProfileRead(credential: AccountCredential, accountID: UUID, budget: TimeInterval) async -> ProfileRead {
        await withTaskGroup(of: ProfileRead.self) { group -> ProfileRead in
            group.addTask {
                do {
                    return .answered(try await requestProfile(credential: credential, accountID: accountID))
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return .outOfTime
            }
            let first = await group.next() ?? .outOfTime
            group.cancelAll()
            return first
        }
    }

    // MARK: - Reset

    /// Spends one banked limit reset: the one call in this adapter that
    /// spends anything, made only from an explicit, confirmed user action
    /// (see `UsageProvider.useReset`).
    ///
    /// Sends at most one usage read (when no grant is known yet), at most one
    /// profile read (when the organization id is not known and the profile is
    /// not on hold), then one POST. It never refreshes the token itself: a 401
    /// is thrown as `needsLogin` for the scheduler's serialized refresh and
    /// resend with the same `attemptID`.
    func useReset(account: Account, credential: AccountCredential, attemptID: UUID) async throws -> ResetOutcome {
        if Self.isConsoleToken(credential) {
            throw UsageError.needsLogin
        }

        // A resend of an attempt that has already been sent goes to the grant
        // that attempt first named, whatever a later read selects. The
        // request id is the idempotency key only together with its grant: the
        // same id sent to another grant could spend that one too. The pin
        // survives a sign-in, so it is checked against the current
        // organization first: a sign-in to another organization makes the
        // attempt a fresh one there.
        let grantID: String
        let orgUUID: String
        if let pin = await grants.pinned(account.id, attemptID: attemptID) {
            guard let current = try await organizationUUID(for: account, credential: credential) else {
                // The profile names no organization, so there is nowhere to
                // send a reset for this sign-in.
                return .notAvailable
            }
            orgUUID = current
            if pin.organizationUUID == current {
                grantID = pin.grantID
            } else {
                await grants.unpin(account.id)
                guard let selected = try await selectedGrant(for: account, credential: credential) else { return .noCredit }
                grantID = selected
            }
        } else {
            guard let selected = try await selectedGrant(for: account, credential: credential) else { return .noCredit }
            guard let current = try await organizationUUID(for: account, credential: credential) else {
                return .notAvailable
            }
            grantID = selected
            orgUUID = current
        }

        let request = try resetRequest(
            organizationUUID: orgUUID,
            grantID: grantID,
            requestID: attemptID.uuidString.lowercased(),
            accessToken: credential.accessToken
        )
        // Pin before the send: once the POST may have reached the provider,
        // every resend of this attempt to this organization names the same
        // grant.
        await grants.pin(grantID, organizationUUID: orgUUID, for: account.id, attemptID: attemptID)
        let response = try await send(request)
        if response.statusCode != 200 {
            await diagnose(.reset, accountID: account.id, request: request, response: response, retryAfter: retryAfter(from: response))
        }

        switch response.statusCode {
        case 200...299:
            return AnthropicResetParser.outcome(response.body, now: now())
        case 401:
            Self.logger.error("Reset rejected with HTTP 401")
            throw UsageError.needsLogin
        case 403:
            if let message = Self.permissionRefusal(in: response.body) {
                Self.logger.error("Reset forbidden for this organization: \(message, privacy: .public)")
                throw UsageError.forbidden(reason: message)
            }
            Self.logger.error("Reset rejected with HTTP 403")
            throw UsageError.needsLogin
        case 429:
            throw UsageError.rateLimited(retryAfter: retryAfter(from: response))
        case 300...399:
            throw UsageError.redirect
        default:
            Self.logger.error("Reset failed with HTTP \(response.statusCode, privacy: .public)")
            throw UsageError.httpStatus(response.statusCode)
        }
    }

    /// The grant a new attempt spends. Reads usage only when no poll this
    /// launch has read the grant block for this account. A read that found no
    /// grant with a reset left is cached too, and answers `nil` with no
    /// request. A 429 here is thrown as `rateLimited` with its `Retry-After`;
    /// the scheduler keeps resets off while the account is under a backoff
    /// horizon.
    private func selectedGrant(for account: Account, credential: AccountCredential) async throws -> String? {
        if let known = await grants.lookup(account.id) {
            return known
        }
        let body = try await readUsage(accountID: account.id, credential: credential)
        let selected = AnthropicResetParser.parse(body).selectedGrantID
        await grants.remember(selected, for: account.id)
        return selected
    }

    /// The reset POST. Throws, and so sends nothing, when an id fails its
    /// rule. The body carries exactly the program, the grant, and the
    /// request id, which is the idempotency key for this attempt.
    func resetRequest(organizationUUID: String, grantID: String, requestID: String, accessToken: String) throws -> URLRequest {
        guard AnthropicEndpoints.isValidGrantID(grantID),
              AnthropicEndpoints.isValidRequestID(requestID),
              let url = AnthropicEndpoints.resetRateLimits(orgUUID: organizationUUID) else {
            throw UsageError.invalidResponse("reset not sent: malformed grant, request, or organization id")
        }
        var request = authorizedRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "program": AnthropicEndpoints.resetProgram,
            "grant_id": grantID,
            "request_id": requestID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The account's organization id: from the profile already read this
    /// launch, else from one profile read that shares the plan's cache and
    /// hold. A profile on hold, or a read that is refused, throws
    /// `rateLimited` with the time left on the hold, and nothing is sent.
    private func organizationUUID(for account: Account, credential: AccountCredential) async throws -> String? {
        if let known = await plans.known(for: account.id) {
            return known.organizationUUID
        }
        let started = now()
        if let until = await plans.heldUntil(account.id, at: started) {
            throw UsageError.rateLimited(retryAfter: until.timeIntervalSince(started))
        }
        switch try await requestProfile(credential: credential, accountID: account.id) {
        case .read(let profile):
            await plans.remember(profile, for: account.id)
            return profile.organizationUUID
        case .refused(let retryAfter):
            let hold = Self.profileHold(retryAfter: retryAfter)
            await plans.hold(account.id, until: started.addingTimeInterval(hold))
            throw UsageError.rateLimited(retryAfter: hold)
        }
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

        var request = jsonTokenRequest(refreshToken: refreshToken)
        var response = try await send(request)
        if response.statusCode != 200 {
            await diagnose(.refresh, accountID: nil, request: request, response: response)
        }
        if isInvalidGrant(response) {
            throw UsageError.needsLogin
        }
        if response.statusCode == 400 {
            request = formTokenRequest(refreshToken: refreshToken)
            response = try await send(request)
            if response.statusCode != 200 {
                await diagnose(.refresh, accountID: nil, request: request, response: response, message: "form-encoded fallback")
            }
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

        var refreshTokenExpiresAt = previous.refreshTokenExpiresAt
        if let seconds = root["refresh_token_expires_in"] as? NSNumber {
            refreshTokenExpiresAt = now().addingTimeInterval(seconds.doubleValue)
        } else if let text = root["refresh_token_expires_in"] as? String, let seconds = Double(text) {
            refreshTokenExpiresAt = now().addingTimeInterval(seconds)
        }

        return AccountCredential(
            accessToken: accessToken,
            refreshToken: nonEmpty(root["refresh_token"] as? String) ?? previous.refreshToken,
            expiresAt: expiresAt,
            accountID: previous.accountID,
            scopes: scopes,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            idToken: previous.idToken
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

    /// One diagnostics line for a non-200 exchange. `DiagnosticEvent` drops
    /// the bearer header and redacts the body before anything is written.
    private func diagnose(
        _ kind: DiagnosticEvent.Kind,
        accountID: UUID?,
        request: URLRequest,
        response: HTTPResponse,
        retryAfter: TimeInterval? = nil,
        message: String? = nil
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(DiagnosticEvent(
            ts: now(),
            provider: .anthropic,
            accountID: accountID,
            kind: kind,
            request: request,
            response: response,
            retryAfter: retryAfter,
            message: message
        ))
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

/// What the adapter knows about each account's profile this launch: the plan
/// and organization id a successful read reported, or how long a refused
/// read must wait. An account with neither is read on its next poll. Memory
/// only: the organization id is never persisted.
private actor ProfilePlanCache {
    struct Known: Sendable {
        let plan: String?
        let organizationUUID: String?
    }

    private var known: [UUID: Known] = [:]
    private var notBefore: [UUID: Date] = [:]

    func known(for id: UUID) -> Known? {
        known[id]
    }

    func remember(_ profile: AnthropicProfile, for id: UUID) {
        known[id] = Known(plan: profile.planLabel, organizationUUID: profile.organizationUUID)
        notBefore[id] = nil
    }

    func isHeld(_ id: UUID, at now: Date) -> Bool {
        guard let until = notBefore[id] else { return false }
        return now < until
    }

    /// When the wait on this account's profile ends, if one is running.
    func heldUntil(_ id: UUID, at now: Date) -> Date? {
        guard let until = notBefore[id], now < until else { return nil }
        return until
    }

    func hold(_ id: UUID, until: Date) {
        notBefore[id] = until
    }

    func forget(_ id: UUID) {
        known[id] = nil
        notBefore[id] = nil
    }
}

/// The grant each account's last successful usage read selected, so a reset
/// usually needs no usage read of its own, and the grant and organization
/// each account's latest reset attempt was sent to. Memory only: a grant id,
/// organization id, or attempt id is never persisted.
private actor ResetGrantCache {
    struct Pin: Sendable {
        let attemptID: UUID
        let grantID: String
        let organizationUUID: String
    }

    /// Present once a usage read this launch has seen the account; the value
    /// is `nil` when that read found no grant with a reset left.
    private var selected: [UUID: String?] = [:]
    /// The latest attempt sent for each account, the grant it named, and the
    /// organization it went to. Only one attempt per account is kept: a new
    /// attempt replaces it.
    private var pins: [UUID: Pin] = [:]

    /// `nil` when the account has not been read this launch; `.some(nil)`
    /// when its last read found no grant to spend.
    func lookup(_ id: UUID) -> String?? {
        selected[id]
    }

    func remember(_ grantID: String?, for id: UUID) {
        selected[id] = .some(grantID)
    }

    /// The pin this attempt was first sent with, or `nil` when the account's
    /// pinned attempt is a different one or there is none.
    func pinned(_ id: UUID, attemptID: UUID) -> Pin? {
        guard let pin = pins[id], pin.attemptID == attemptID else { return nil }
        return pin
    }

    /// Records the grant and organization an attempt is sent to. A pin
    /// already held for the same attempt is kept, so the first send decides.
    func pin(_ grantID: String, organizationUUID: String, for id: UUID, attemptID: UUID) {
        if let pin = pins[id], pin.attemptID == attemptID { return }
        pins[id] = Pin(attemptID: attemptID, grantID: grantID, organizationUUID: organizationUUID)
    }

    /// Drops the account's pin, once its attempt is known to belong to an
    /// organization the account no longer signs in to.
    func unpin(_ id: UUID) {
        pins.removeValue(forKey: id)
    }

    /// Forgets the selected grant after a sign-in. The pin is kept: see
    /// `AnthropicProvider.accountDidSignIn`.
    func forgetSelection(_ id: UUID) {
        selected.removeValue(forKey: id)
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
