import Foundation

/// One account's most recent known status plus what the scheduler learned on
/// its last attempt. This is what the UI reads; the UI never sees a provider.
struct CachedStatus: Codable, Hashable, Sendable {
    /// The status to draw. After a failed attempt this still carries the last
    /// good windows and their `fetchedAt`, with `state` describing the failure,
    /// so the row dims rather than blanks (ISC-97).
    var status: AccountStatus
    /// Windows from the last successful fetch, `nil` when none has succeeded.
    var lastGoodWindows: [UsageWindow]?
    /// True when the last attempt failed or timed out, or when the data is
    /// older than `staleAfter` (ISC-104). Never true for a fresh success.
    var isStale: Bool
    /// When the scheduler last tried this account, successful or not.
    var lastAttempt: Date
    /// Redacted, user-readable reason for the last failure. `nil` on success.
    var lastError: String?
    /// When the scheduler will try again, set while a backoff horizon is
    /// active. `nil` when the next cycle will fetch normally.
    var nextAttemptAt: Date?
}

/// The one place the UI reads account status from.
///
/// The poll scheduler writes here after every attempt. The menu bar rotation
/// (every 10 s, in `UI/`) and the detail window read `snapshot()` or iterate
/// `updates()`. Neither call reaches the scheduler, the store, or a provider,
/// so reading the cache as often as you like costs zero network requests
/// (ISC-103). A hung or failed fetch keeps the last good windows and marks the
/// entry stale rather than clearing it (ISC-97).
actor StatusCache {
    private let clock: any PollClock
    /// Age beyond which a status is stale regardless of how it was produced.
    let staleAfter: TimeInterval

    private var entries: [UUID: CachedStatus] = [:]
    /// Accounts dropped by `retain` or `forget`. Account ids are never
    /// reused, so a write for one of these is a read that finished after its
    /// row was removed, and is refused rather than bringing the row back.
    private var removed: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<[UUID: CachedStatus]>.Continuation] = [:]

    init(clock: any PollClock, staleAfter: TimeInterval) {
        self.clock = clock
        self.staleAfter = staleAfter
    }

    // MARK: Reading

    /// Every cached account, keyed by account id, with `isStale` evaluated at
    /// the current time.
    func snapshot() -> [UUID: CachedStatus] {
        let now = clock.now()
        return entries.mapValues { applyingAge($0, now: now) }
    }

    /// One account's entry, or `nil` before its first attempt.
    func entry(for id: UUID) -> CachedStatus? {
        entries[id].map { applyingAge($0, now: clock.now()) }
    }

    /// A stream that yields the full snapshot after every change. The current
    /// snapshot is yielded first so a late subscriber starts populated.
    func updates() -> AsyncStream<[UUID: CachedStatus]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[UUID: CachedStatus]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    // MARK: Seeding (launch only)

    /// Installs entries persisted by a previous run (ISC-90), so the rows show
    /// their last known numbers before the first fetch completes. Only accounts
    /// with no live entry are seeded; a seeded entry is dimmed by the age rule
    /// like any other and is replaced by the first attempt of this run.
    func seed(from persisted: [UUID: CachedStatus]) {
        var changed = false
        for (id, entry) in persisted where entries[id] == nil {
            var seeded = entry
            seeded.nextAttemptAt = nil
            entries[id] = seeded
            changed = true
        }
        if changed { publish() }
    }

    // MARK: Writing (scheduler only)

    /// A successful fetch. The entry becomes current and its last good windows
    /// are replaced.
    func recordSuccess(_ status: AccountStatus, at attempt: Date) {
        guard !removed.contains(status.accountID) else { return }
        entries[status.accountID] = CachedStatus(
            status: status,
            lastGoodWindows: status.windows,
            isStale: false,
            lastAttempt: attempt,
            lastError: nil,
            nextAttemptAt: nil
        )
        publish()
    }

    /// A failed attempt. The last good windows and their `fetchedAt` survive;
    /// only `state`, `lastError`, staleness, and the next-attempt horizon
    /// change. `markStale` is false for a rate limit, where the data is as good
    /// as it was a moment ago and only its age should dim it.
    func recordFailure(
        account: Account,
        state: AccountState,
        error: String?,
        at attempt: Date,
        markStale: Bool,
        nextAttemptAt: Date? = nil
    ) {
        guard !removed.contains(account.id) else { return }
        let previous = entries[account.id]
        let windows = previous?.lastGoodWindows ?? []
        let status = AccountStatus(
            accountID: account.id,
            provider: account.provider,
            email: account.email,
            windows: windows,
            fetchedAt: previous?.status.fetchedAt ?? attempt,
            state: state,
            planLabel: previous?.status.planLabel,
            resetCreditsAvailable: previous?.status.resetCreditsAvailable
        )
        entries[account.id] = CachedStatus(
            status: status,
            lastGoodWindows: previous?.lastGoodWindows,
            isStale: markStale || (previous?.isStale ?? false),
            lastAttempt: attempt,
            lastError: error,
            nextAttemptAt: nextAttemptAt
        )
        publish()
    }

    /// The scheduler skipped this account because a backoff horizon is active.
    /// Nothing about the data changes. When the horizon is a rate limit the
    /// state says so, because that is why the numbers are not moving; an error
    /// backoff keeps the error the row already shows.
    func recordSkipped(account: Account, until: Date, rateLimited: Bool, at attempt: Date) {
        guard !removed.contains(account.id) else { return }
        guard var entry = entries[account.id] else {
            recordFailure(
                account: account,
                state: rateLimited ? .rateLimited(until: until) : .error("Waiting to retry"),
                error: nil,
                at: attempt,
                markStale: false,
                nextAttemptAt: until
            )
            return
        }
        entry.nextAttemptAt = until
        entry.lastAttempt = attempt
        if rateLimited {
            entry.status = Self.replacingState(of: entry.status, with: .rateLimited(until: until))
        }
        entries[account.id] = entry
        publish()
    }

    /// Drops entries for accounts that no longer exist in the store. The
    /// dropped accounts stay refused for the life of the process.
    func retain(accountIDs: Set<UUID>) {
        let dropped = entries.keys.filter { !accountIDs.contains($0) }
        guard !dropped.isEmpty else { return }
        removed.formUnion(dropped)
        for id in dropped {
            entries[id] = nil
        }
        publish()
    }

    /// The account was removed: drops its entry and refuses every later
    /// write for it, so a read that was already running when the row went
    /// away cannot bring it back.
    func forget(_ accountID: UUID) {
        removed.insert(accountID)
        if entries.removeValue(forKey: accountID) != nil { publish() }
    }

    // MARK: Helpers

    private func publish() {
        let snapshot = snapshot()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Age-based staleness (ISC-104): data older than `staleAfter` is stale even
    /// when the last attempt succeeded. Entries that never succeeded have
    /// nothing to age; their `isStale` is whatever the failure set.
    private func applyingAge(_ entry: CachedStatus, now: Date) -> CachedStatus {
        guard entry.lastGoodWindows != nil else { return entry }
        var entry = entry
        if now.timeIntervalSince(entry.status.fetchedAt) > staleAfter {
            entry.isStale = true
        }
        return entry
    }

    private static func replacingState(of status: AccountStatus, with state: AccountState) -> AccountStatus {
        AccountStatus(
            accountID: status.accountID,
            provider: status.provider,
            email: status.email,
            windows: status.windows,
            fetchedAt: status.fetchedAt,
            state: state,
            planLabel: status.planLabel,
            resetCreditsAvailable: status.resetCreditsAvailable
        )
    }
}
