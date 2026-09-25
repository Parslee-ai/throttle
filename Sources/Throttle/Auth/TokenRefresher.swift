import Foundation
import OSLog

/// Hands out a credential that is good for at least the next minute,
/// refreshing it first when it is not (ISC-62/63/64, 83/84).
///
/// One instance serves the whole app. For each account it keeps at most one
/// refresh in flight: every caller that arrives while it runs awaits the same
/// task, so ten concurrent polls of one account produce one refresh request.
/// The refresh runs in a detached task, so cancelling a caller (a poll cycle
/// being torn down, say) never cancels the rotation itself. The rotated pair
/// is written back to the store before any caller receives it, so nothing can
/// use a token the Keychain does not yet hold.
///
/// A refresh that fails with `UsageError.needsLogin` propagates to every
/// waiting caller. The scheduler marks the account as needing login; nothing
/// here ever deletes an account or its credential.
actor TokenRefresher {
    /// A credential expiring within this many seconds is refreshed first.
    static let expiryLeeway: TimeInterval = 60

    private let now: @Sendable () -> Date
    private var inFlight: [UUID: Task<AccountCredential, Error>] = [:]

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// The account's stored credential, refreshed and persisted first when it
    /// expires within `expiryLeeway`. Throws `UsageError.needsLogin` when the
    /// store holds no credential or the provider rejects the refresh token.
    func validCredential(
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential {
        if let task = inFlight[account.id] {
            return try await task.value
        }

        let now = self.now
        let task = Task.detached(priority: .userInitiated) {
            guard let stored = try await store.credential(for: account.id) else {
                Logger(subsystem: "ai.parslee.throttle", category: "TokenRefresher")
                    .error("No stored credential for account \(account.id.uuidString, privacy: .public)")
                throw UsageError.needsLogin
            }
            guard Self.needsRefresh(stored, now: now()) else {
                return stored
            }
            let rotated = try await provider.refresh(credential: stored)
            try await store.updateCredential(rotated, for: account.id)
            return rotated
        }
        return try await run(task, for: account.id)
    }

    /// A credential other than `rejected`, which the provider just answered
    /// 401 to. When the store already holds a different credential (another
    /// caller rotated it meanwhile) that one is returned with no request;
    /// otherwise the stored pair is refreshed once, persisted, and returned.
    ///
    /// Same guarantees as `validCredential`: at most one refresh per account
    /// in flight, a caller that arrives during one waits for it, and the
    /// refresh runs detached so cancelling a caller never cancels it. A
    /// rejected refresh throws `UsageError.needsLogin`.
    func refreshedCredential(
        replacing rejected: AccountCredential,
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential {
        // Let whatever is already running finish first; it may have rotated
        // the pair already. Each task is awaited once, so a finished task
        // still parked in the map cannot spin this loop.
        var awaited: Task<AccountCredential, Error>?
        while let task = inFlight[account.id], task != awaited {
            awaited = task
            let current = try await task.value
            if current.accessToken != rejected.accessToken { return current }
        }

        let task = Task.detached(priority: .userInitiated) {
            guard let stored = try await store.credential(for: account.id) else {
                throw UsageError.needsLogin
            }
            guard stored.accessToken == rejected.accessToken else {
                return stored
            }
            let rotated = try await provider.refresh(credential: stored)
            try await store.updateCredential(rotated, for: account.id)
            return rotated
        }
        return try await run(task, for: account.id)
    }

    /// Parks `task` as the account's one refresh in flight until it ends. It
    /// clears only its own slot, so a later task is never unparked by an
    /// earlier caller resuming late.
    private func run(
        _ task: Task<AccountCredential, Error>,
        for accountID: UUID
    ) async throws -> AccountCredential {
        inFlight[accountID] = task
        defer {
            if inFlight[accountID] == task { inFlight[accountID] = nil }
        }
        return try await task.value
    }

    /// Whether the credential expires within the leeway. `expiresAt` wins;
    /// without it the access token's `exp` claim is used when the token is a
    /// JWT (OpenAI). A credential with no discoverable expiry is used as-is,
    /// and a 401 on the fetch then drives the account to needs-login.
    static func needsRefresh(_ credential: AccountCredential, now: Date) -> Bool {
        let expiresAt = credential.expiresAt ?? JWTClaims.decode(credential.accessToken)?.exp
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < expiryLeeway
    }
}
