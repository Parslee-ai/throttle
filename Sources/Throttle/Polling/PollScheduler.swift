import AppKit
import Foundation
import os

/// Hands the scheduler a credential it can use right now.
///
/// The production conformer is `TokenRefresher` (under `Auth/`), which refreshes
/// an expiring token once per account no matter how many callers ask, and never
/// cancels a refresh in flight. The scheduler depends on this protocol only, so
/// it can be tested with `PassthroughCredentialResolver`.
protocol CredentialResolving: Sendable {
    func validCredential(
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential

    /// A credential other than `rejected`, which the provider just answered
    /// 401 to: refreshed once if the store still holds `rejected`, or the one
    /// another caller already rotated in. Same serialization and
    /// never-cancelled rules as `validCredential`. Throws
    /// `UsageError.needsLogin` when no usable credential can be had.
    func refreshedCredential(
        replacing rejected: AccountCredential,
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential
}

/// Loads the stored credential as-is. No refresh. The default when no
/// `TokenRefresher` is wired, and the test double.
struct PassthroughCredentialResolver: CredentialResolving {
    init() {}

    func validCredential(
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential {
        guard let credential = try await store.credential(for: account.id) else {
            throw UsageError.needsLogin
        }
        return credential
    }

    /// Cannot refresh: hands back the stored credential when it differs from
    /// the rejected one, otherwise reports that a sign-in is needed.
    func refreshedCredential(
        replacing rejected: AccountCredential,
        for account: Account,
        from store: AccountStore,
        using provider: any UsageProvider
    ) async throws -> AccountCredential {
        guard let credential = try await store.credential(for: account.id),
              credential.accessToken != rejected.accessToken else {
            throw UsageError.needsLogin
        }
        return credential
    }
}

/// The per-account budget ran out before the fetch finished.
struct PollTimeoutError: Error, Hashable, Sendable {
    let seconds: TimeInterval
}

/// Fetches every account's usage on a fixed cadence and writes the result to a
/// `StatusCache`.
///
/// One cycle (ISC-96, ISC-97):
/// 1. Read the accounts from the store. Any whose Keychain item is gone become
///    `.needsLogin` in the cache with no request.
/// 2. Group the rest by provider. Providers run concurrently; the accounts of
///    one provider run one after another with `stagger` seconds between request
///    starts, so a provider never sees a burst.
/// 3. Each account gets `perAccountTimeout` for credential resolution plus the
///    usage request. On expiry the fetch is abandoned, logged once, and the
///    cache keeps the last good windows marked stale.
/// 4. The whole cycle gets `cycleDeadline`. Accounts still pending when it
///    expires are marked stale without a request.
///
/// Cycles are single-flight (ISC-98): a timer tick that lands while a cycle is
/// running is dropped, never queued. `refreshNow()` (ISC-101) is the one
/// exception: it is queued at most once and runs when the current cycle ends,
/// because a person who clicked Refresh during a cycle wants numbers newer than
/// the ones that cycle was already fetching. Both paths respect backoff.
///
/// Backoff (ISC-99, ISC-100) is delegated to `BackoffPolicy`; an account under
/// an active horizon is skipped for the cycle and its cache entry shows the
/// horizon.
///
/// Rotation independence (ISC-103): the scheduler exposes nothing about its
/// timer. The 10 s menu bar rotation lives in `UI/`, reads `StatusCache` only,
/// and never calls the scheduler. Reading the cache any number of times issues
/// zero requests; `PollSchedulerTests` asserts it.
///
/// `stop()` cancels the timer and the cycle in flight. It never reaches into a
/// credential refresh: the resolver owns those and lets them finish (D-7).
///
/// Spending a banked reset (`useReset`) is the one call here that is not a
/// read. Only an explicit, confirmed user action reaches it; no cycle, timer
/// tick, wake, or launch path calls it. It shares the resolver with polling,
/// so a reset and a poll that both need a refresh produce one refresh.
actor PollScheduler {
    private enum Trigger: String {
        case start, timer, refreshNow, wake
    }

    private let store: AccountStore
    private let providers: [Provider: any UsageProvider]
    private let resolver: any CredentialResolving
    private let cache: StatusCache
    private let clock: any PollClock
    private let logger = Logger(subsystem: "ai.parslee.throttle", category: "PollScheduler")

    private(set) var settings: PollSettings
    private var backoff: BackoffPolicy
    /// Where the provider-wide rate-limit horizon outlives the process. `nil`
    /// keeps everything in memory.
    private let backoffPersistence: BackoffPersistence?
    /// What was last written, so an unchanged horizon is not rewritten on
    /// every success.
    private var persistedHorizons: [Provider: Date]?
    /// The on-disk diagnostics log, if the app wired one.
    private let diagnostics: Diagnostics?

    private var loopTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var refreshQueued = false
    /// True between `handleWillSleep()` and `handleDidWake()`.
    private(set) var isPausedForSleep = false
    private var sleepWakeObserver: SleepWakeObserver?

    /// Accounts the running cycle has finished with (fetched, skipped, or
    /// flagged needs-login). Whatever is not here when the deadline hits is
    /// marked stale.
    private var settledThisCycle: Set<UUID> = []

    /// Accounts with a reset attempt running. A second attempt for one of
    /// them is refused without a request.
    private var resetsInFlight: Set<UUID> = []

    /// The one usage read in flight per account, and who is waiting for it
    /// to end. A poll and the read after a reset never overlap for one
    /// account: whichever comes second waits for the first.
    private struct ReadSlot {
        let sequence: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private var readSlots: [UUID: ReadSlot] = [:]
    /// Numbers every usage read in start order.
    private var readSequence = 0
    /// The sequence number of each account's latest read that succeeded.
    private var lastSuccessfulRead: [UUID: Int] = [:]

    /// Budget for each reset request, including the credential it needs. A
    /// reset still running when it expires is reported as unreachable; the
    /// user's retry reuses the same attempt id, so it cannot spend twice.
    static let resetTimeout: TimeInterval = 20

    /// How long the read after a reset waits first, in seconds. A provider
    /// answers `reset` before its usage endpoint reflects it: a read in the
    /// same second still showed the old numbers, while one 43 s later showed
    /// the new ones. Waited on the scheduler's clock, so tests drive it.
    static let postResetReadDelay: TimeInterval = 5

    /// This scheduler's settle delay: `postResetReadDelay` in the app. Tests
    /// that are not about the delay pass 0 so a reset returns without the
    /// test advancing the clock.
    private let resetReadDelay: TimeInterval

    /// Cycles that ran to completion or to their deadline. Tests wait on this.
    private(set) var completedCycles = 0
    /// Cycles that started. Differs from `completedCycles` only mid-cycle.
    private(set) var startedCycles = 0
    /// Callers of `waitForCompletedCycles` and the count each waits for.
    private var cycleWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        store: AccountStore,
        providers: [Provider: any UsageProvider],
        resolver: any CredentialResolving,
        cache: StatusCache,
        settings: PollSettings,
        clock: any PollClock,
        backoff: BackoffPolicy = BackoffPolicy(),
        backoffPersistence: BackoffPersistence? = nil,
        diagnostics: Diagnostics? = nil,
        postResetReadDelay: TimeInterval = PollScheduler.postResetReadDelay
    ) {
        self.resetReadDelay = max(0, postResetReadDelay)
        self.store = store
        self.providers = providers
        self.resolver = resolver
        self.cache = cache
        self.settings = settings
        self.clock = clock
        self.backoff = backoff
        self.backoffPersistence = backoffPersistence
        self.diagnostics = diagnostics
    }

    // MARK: Lifecycle

    /// Runs one cycle now and another every `pollInterval`. Calling it while
    /// running is a no-op. A provider-wide rate-limit horizon saved by the
    /// previous run is restored first, so the first cycle skips those accounts
    /// instead of extending the penalty with one more request.
    func start() {
        guard loopTask == nil else { return }
        isPausedForSleep = false
        seedBackoffFromDisk()
        startLoop()
    }

    /// Stops the timer and abandons the cycle in flight. In-flight credential
    /// refreshes are the resolver's and are not touched.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        cycleTask?.cancel()
        refreshQueued = false
        isPausedForSleep = false
    }

    /// True between `start()` and `stop()`, including while paused for sleep.
    var isRunning: Bool {
        loopTask != nil || isPausedForSleep
    }

    /// Whether a cycle is executing right now.
    var isCycleInFlight: Bool {
        cycleTask != nil
    }

    /// Applies new settings. A running timer restarts so a shorter interval
    /// takes effect without waiting out the old one; no extra cycle runs.
    func update(settings: PollSettings) {
        self.settings = settings
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        startLoop(runImmediately: false)
    }

    /// Forces one cycle regardless of cadence (ISC-101). Backoff still applies
    /// to every account. If a cycle is running, one refresh is queued to run
    /// after it; further calls while queued are dropped.
    func refreshNow() {
        if cycleTask != nil {
            refreshQueued = true
            return
        }
        launchCycle(trigger: .refreshNow)
    }

    /// The user's override for a provider throttle: forgets the provider's
    /// rate-limit horizon (and the per-account horizons of its accounts),
    /// writes the cleared state to disk so a relaunch does not restore it,
    /// and runs one cycle now. The provider may answer 429 again, in which
    /// case a fresh horizon is armed from its `Retry-After`. A forbidden hold
    /// (D-33) is not cleared: those accounts stay skipped.
    func retryProvider(_ provider: Provider) async {
        let accounts = await store.accounts().filter { $0.provider == provider }.map(\.id)
        backoff.clearHorizon(provider: provider, accounts: accounts)
        persistBackoffIfChanged()
        logger.notice("Retry-now override cleared the \(provider.displayName, privacy: .public) rate-limit horizon")
        await diagnostics?.record(DiagnosticEvent(
            ts: clock.now(),
            provider: provider,
            accountID: nil,
            kind: .scheduler,
            message: "Retry-now override cleared the rate-limit horizon for \(accounts.count) account(s)"
        ))
        refreshNow()
    }

    // MARK: Sleep and wake (ISC-102)

    /// Starts observing the Mac's sleep and wake notifications on the given
    /// center. `NSWorkspace.shared.notificationCenter` is the real one; tests
    /// pass a private `NotificationCenter` and post the same names.
    func observeSleepWake(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        sleepWakeObserver = SleepWakeObserver(
            center: center,
            onSleep: { [weak self] in
                guard let self else { return }
                Task { await self.handleWillSleep() }
            },
            onWake: { [weak self] in
                guard let self else { return }
                Task { await self.handleDidWake() }
            }
        )
    }

    /// The Mac is about to sleep: stop the timer. A cycle in flight is left to
    /// hit its own timeouts; the network is going away regardless.
    func handleWillSleep() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        isPausedForSleep = true
    }

    /// The Mac woke: run one cycle immediately and resume the timer from now.
    /// Called on a scheduler that was never started, it does nothing.
    func handleDidWake() {
        guard isPausedForSleep else {
            if loopTask != nil { launchCycle(trigger: .wake) }
            return
        }
        isPausedForSleep = false
        startLoop()
    }

    // MARK: Persisted backoff (ISC-99 across relaunches)

    private func seedBackoffFromDisk() {
        guard let backoffPersistence else { return }
        let now = clock.now()
        let saved = backoffPersistence.load()
        backoff.seed(providerHorizons: saved, now: now)
        for (provider, until) in saved where until > now {
            logger.notice("Restored \(provider.displayName, privacy: .public) rate-limit horizon until \(until.formatted(.iso8601), privacy: .public)")
        }
        persistedHorizons = backoff.providerHorizons(now: now)
    }

    /// Writes the active provider horizons if they differ from the last write.
    private func persistBackoffIfChanged() {
        guard let backoffPersistence else { return }
        let current = backoff.providerHorizons(now: clock.now())
        guard current != persistedHorizons else { return }
        backoffPersistence.save(current)
        persistedHorizons = current
    }

    // MARK: Timer loop

    /// The timer. Ticks are fire-and-forget: the loop never waits for a cycle,
    /// so a slow cycle cannot shift the cadence, and a tick during a cycle is
    /// dropped by `launchCycle`.
    private func startLoop(runImmediately: Bool = true) {
        loopTask = Task { [weak self] in
            if runImmediately {
                await self?.launchCycle(trigger: .start)
            }
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.settings.pollInterval
                do {
                    try await self.clock.sleep(for: interval)
                } catch {
                    return
                }
                await self.launchCycle(trigger: .timer)
            }
        }
    }

    /// Single-flight gate (ISC-98). Starts a cycle unless one is running.
    private func launchCycle(trigger: Trigger) {
        guard cycleTask == nil else {
            logger.debug("Dropped \(trigger.rawValue, privacy: .public) cycle: one is already in flight")
            return
        }
        startedCycles += 1
        cycleTask = Task { [weak self] in
            await self?.performCycle(trigger: trigger)
            await self?.cycleDidFinish()
        }
    }

    /// Returns once `completedCycles` reaches `count`, so a test waits for
    /// the cycle's end itself rather than polling the counter.
    func waitForCompletedCycles(_ count: Int) async {
        guard completedCycles < count else { return }
        await withCheckedContinuation { continuation in
            cycleWaiters.append((count, continuation))
        }
    }

    private func cycleDidFinish() {
        cycleTask = nil
        completedCycles += 1
        let done = completedCycles
        let ready = cycleWaiters.filter { $0.count <= done }
        cycleWaiters.removeAll { $0.count <= done }
        for waiter in ready { waiter.continuation.resume() }
        if refreshQueued {
            refreshQueued = false
            launchCycle(trigger: .refreshNow)
        }
    }

    // MARK: One cycle

    private func performCycle(trigger: Trigger) async {
        settledThisCycle = []
        let accounts = await store.accounts()
        let missing = Set(await store.missingCredentialIDs())
        await cache.retain(accountIDs: Set(accounts.map(\.id)))

        var pending: [Account] = []
        for account in accounts {
            if missing.contains(account.id) {
                await cache.recordFailure(
                    account: account,
                    state: .needsLogin,
                    error: nil,
                    at: clock.now(),
                    markStale: true
                )
                settledThisCycle.insert(account.id)
            } else {
                pending.append(account)
            }
        }

        // Display order within each provider is preserved by the grouping.
        var groups: [Provider: [Account]] = [:]
        for account in pending {
            groups[account.provider, default: []].append(account)
        }

        let deadline = settings.cycleDeadline
        let hitDeadline = await withTaskGroup(of: Bool.self) { race in
            race.addTask { [groups] in
                await withTaskGroup(of: Void.self) { providersGroup in
                    for (provider, accounts) in groups {
                        providersGroup.addTask {
                            await self.pollSequentially(accounts, provider: provider)
                        }
                    }
                }
                return false
            }
            race.addTask { [clock] in
                do {
                    try await clock.sleep(for: deadline)
                    return true
                } catch {
                    return false
                }
            }
            let first = await race.next() ?? false
            race.cancelAll()
            return first
        }

        if hitDeadline {
            let now = clock.now()
            let abandoned = pending.filter { !settledThisCycle.contains($0.id) }
            logger.error("Poll cycle hit its \(deadline, privacy: .public)s deadline with \(abandoned.count, privacy: .public) account(s) pending")
            for account in abandoned {
                await cache.recordFailure(
                    account: account,
                    state: .error("Poll cycle timed out"),
                    error: "Poll cycle deadline of \(Int(deadline)) s reached before this account was fetched",
                    at: now,
                    markStale: true
                )
            }
        }
    }

    /// One provider's accounts, one at a time, with `stagger` between request
    /// starts. Skipped accounts issue no request and so add no stagger.
    private func pollSequentially(_ accounts: [Account], provider: Provider) async {
        var issuedRequest = false
        for account in accounts {
            if Task.isCancelled { return }
            if issuedRequest {
                do {
                    try await clock.sleep(for: settings.stagger)
                } catch {
                    return
                }
            }
            issuedRequest = await poll(account, provider: provider) || issuedRequest
        }
    }

    /// Fetches one account. Returns true when a request was actually started.
    private func poll(_ account: Account, provider: Provider) async -> Bool {
        // The read after a reset is running for this account: wait for it,
        // and when it brought a fresh reading, that reading is this cycle's.
        if let running = readSlots[account.id]?.sequence {
            await waitForReadInFlight(account.id)
            if (lastSuccessfulRead[account.id] ?? 0) >= running {
                settledThisCycle.insert(account.id)
                return false
            }
        }

        let attemptAt = clock.now()

        if let until = backoff.shouldSkip(account: account.id, provider: provider, now: attemptAt) {
            // A forbidden hold keeps its own state on the row even when a
            // provider-wide 429 is also active; the refusal is the reason the
            // account cannot be read, whatever the throttle does.
            let forbidden = backoff.forbiddenUntil(account: account.id, now: attemptAt) != nil
            let rateLimited = !forbidden
                && backoff.rateLimitedUntil(account: account.id, provider: provider, now: attemptAt) != nil
            await cache.recordSkipped(account: account, until: until, rateLimited: rateLimited, at: attemptAt)
            settledThisCycle.insert(account.id)
            return false
        }

        guard let adapter = providers[provider] else {
            await cache.recordFailure(
                account: account,
                state: .error("No adapter for \(provider.displayName)"),
                error: "No usage adapter is registered for \(provider.displayName)",
                at: attemptAt,
                markStale: true
            )
            settledThisCycle.insert(account.id)
            return false
        }

        guard await fetchAndRecord(account, adapter: adapter, provider: provider, attemptAt: attemptAt) else {
            // The cycle deadline or stop() cancelled us. The deadline path
            // marks the account stale; stop() wants nothing recorded.
            return true
        }
        settledThisCycle.insert(account.id)
        return true
    }

    /// Reads one account's usage under `perAccountTimeout` and records the
    /// result in the cache and the backoff policy. Returns false when the
    /// caller was cancelled, in which case nothing is recorded.
    ///
    /// With `onlyIfStillStored`, the result is dropped when the account left
    /// the store while the read ran, so a removed row never gets its entry
    /// back. A removal that lands after that check is caught by the cache
    /// itself, which refuses writes for an account it was told is gone.
    ///
    /// The caller must have waited out any read in flight for the account
    /// (`waitForReadInFlight`) with no suspension since: this claims the
    /// account's read slot before its first `await`.
    private func fetchAndRecord(
        _ account: Account,
        adapter: any UsageProvider,
        provider: Provider,
        attemptAt: Date,
        onlyIfStillStored: Bool = false
    ) async -> Bool {
        let sequence = beginRead(account.id)
        defer { endRead(account.id) }
        let timeout = settings.perAccountTimeout
        let store = store
        let resolver = resolver
        let clock = clock
        let deadline = clock.now().addingTimeInterval(timeout)
        let remaining: @Sendable () -> TimeInterval = { deadline.timeIntervalSince(clock.now()) }
        do {
            let status = try await withTimeout(timeout) {
                // Bound inside the timed work, which runs detached and would
                // not inherit it from here.
                try await FetchBudget.$remaining.withValue(remaining) {
                    let credential = try await resolver.validCredential(for: account, from: store, using: adapter)
                    return try await adapter.fetchStatus(account: account, credential: credential)
                }
            }
            if onlyIfStillStored, await storedAccount(account.id) == nil { return true }
            backoff.record(outcome: .success, for: account.id, provider: provider, now: clock.now())
            persistBackoffIfChanged()
            lastSuccessfulRead[account.id] = sequence
            await cache.recordSuccess(status, at: attemptAt)
            await diagnostics?.record(DiagnosticEvent(
                ts: clock.now(),
                provider: provider,
                accountID: account.id,
                kind: .usage,
                status: 200
            ))
        } catch is CancellationError {
            return false
        } catch {
            if Task.isCancelled { return false }
            if onlyIfStillStored, await storedAccount(account.id) == nil { return true }
            await record(error: error, for: account, provider: provider, attemptAt: attemptAt)
        }
        return true
    }

    private func storedAccount(_ id: UUID) async -> Account? {
        await store.accounts().first { $0.id == id }
    }

    // MARK: One read per account

    private func beginRead(_ id: UUID) -> Int {
        assert(readSlots[id] == nil, "a second concurrent usage read for one account")
        readSequence += 1
        readSlots[id] = ReadSlot(sequence: readSequence, waiters: readSlots[id]?.waiters ?? [])
        return readSequence
    }

    private func endRead(_ id: UUID) {
        let waiters = readSlots.removeValue(forKey: id)?.waiters ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns once no usage read is in flight for the account. Nothing may
    /// suspend between this returning and the caller's `beginRead`.
    private func waitForReadInFlight(_ id: UUID) async {
        while readSlots[id] != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                readSlots[id]?.waiters.append(continuation)
            }
        }
    }

    // MARK: Banked reset (user action only)

    /// Spends one banked limit reset for the account, on the user's explicit,
    /// confirmed request. Nothing in the poll cycle, the timer, wake, or launch
    /// calls this.
    ///
    /// - A second call for an account whose reset is still running returns
    ///   `.alreadyRunning` and sends nothing.
    /// - The credential comes from the same resolver polling uses. A 401 on
    ///   the reset forces one refresh and resends with the same `attemptID`;
    ///   a second 401 flags the account `needsLogin` and keeps its row.
    /// - A 429 on the reset is reported with its time and leaves the poll
    ///   backoff exactly as it was.
    /// - After a spend, after any answer that means the count is out of
    ///   date, and after a 5xx (the reset may have been spent), that one
    ///   account's usage is read once, `postResetReadDelay` after the answer
    ///   so the provider has settled, unless its provider or
    ///   the account is under a backoff horizon, in which case the row keeps
    ///   its last good reading with its age. No other account is touched.
    /// - An account removed while the reset ran gets no cache entry back.
    /// - While the account or its provider is under a backoff horizon (a rate
    ///   limit, an error backoff, or a forbidden hold), nothing is sent: the
    ///   result is `.rateLimited(until:)` with the horizon's end, because one
    ///   more request only extends the penalty.
    /// - The read after the reset never overlaps a poll's read of the same
    ///   account. It waits for one in flight, and skips when a read that
    ///   started after the reset finished has already succeeded.
    func useReset(accountID: UUID, attemptID: UUID) async -> ResetResult {
        guard resetsInFlight.insert(accountID).inserted else {
            return .alreadyRunning
        }
        defer { resetsInFlight.remove(accountID) }

        guard let account = await storedAccount(accountID) else { return .unsupported }
        let provider = account.provider
        guard let adapter = providers[provider] else { return .unsupported }

        let result: ResetResult
        if let until = backoff.shouldSkip(account: accountID, provider: provider, now: clock.now()) {
            result = .rateLimited(until: until)
            await diagnose(account, provider: provider, at: clock.now(),
                           message: "Reset not sent; backing off until \(until.formatted(.iso8601))")
        } else {
            result = await attemptReset(account, adapter: adapter, attemptID: attemptID)
        }
        // Reads numbered above this one started after the reset finished.
        let completedAt = readSequence
        await diagnostics?.record(DiagnosticEvent(
            ts: clock.now(),
            provider: provider,
            accountID: accountID,
            kind: .scheduler,
            message: "Reset attempt ended: \(Self.logDescription(of: result))"
        ))

        if result == .needsLogin, let current = await storedAccount(accountID) {
            await record(error: UsageError.needsLogin, for: current, provider: provider, attemptAt: clock.now())
        }
        if result.wantsUsageRead {
            // The account stays in `resetsInFlight` through the wait and the
            // read, so a second reset is still refused and the row keeps its
            // spinner until the fresh numbers land. A cancelled wait (the app
            // quitting) sends nothing.
            if resetReadDelay > 0 {
                do {
                    try await clock.sleep(for: resetReadDelay)
                } catch {
                    return result
                }
            }
            await readUsageAfterReset(accountID, provider: provider, completedAt: completedAt)
        }
        return result
    }

    /// Whether a reset is running for the account.
    func isResetInFlight(_ accountID: UUID) -> Bool {
        resetsInFlight.contains(accountID)
    }

    /// Sends the reset, and on an auth rejection refreshes once and resends
    /// the same attempt. Each send has its own `resetTimeout`.
    private func attemptReset(_ account: Account, adapter: any UsageProvider, attemptID: UUID) async -> ResetResult {
        let store = store
        let resolver = resolver
        let clock = clock
        let timeout = Self.resetTimeout
        do {
            let firstDeadline = clock.now().addingTimeInterval(timeout)
            let firstBudget: @Sendable () -> TimeInterval = { firstDeadline.timeIntervalSince(clock.now()) }
            let (credential, first) = try await withTimeout(timeout) { () -> (AccountCredential, Result<ResetOutcome, any Error>) in
                try await FetchBudget.$remaining.withValue(firstBudget) {
                    let credential = try await resolver.validCredential(for: account, from: store, using: adapter)
                    // A caller that gave up while the credential resolved
                    // (the timeout, the app quitting) sends nothing. The
                    // refresh itself is the resolver's and still finishes.
                    try Task.checkCancellation()
                    do {
                        let outcome = try await adapter.useReset(account: account, credential: credential, attemptID: attemptID)
                        return (credential, .success(outcome))
                    } catch {
                        return (credential, .failure(error))
                    }
                }
            }
            switch first {
            case .success(let outcome):
                return .outcome(outcome)
            case .failure(let error) where Self.isAuthRejection(error):
                // One forced refresh, then the same attempt again. A second
                // rejection falls through to `.needsLogin` below.
                let retryDeadline = clock.now().addingTimeInterval(timeout)
                let retryBudget: @Sendable () -> TimeInterval = { retryDeadline.timeIntervalSince(clock.now()) }
                let outcome = try await withTimeout(timeout) {
                    try await FetchBudget.$remaining.withValue(retryBudget) {
                        let fresh = try await resolver.refreshedCredential(
                            replacing: credential,
                            for: account,
                            from: store,
                            using: adapter
                        )
                        try Task.checkCancellation()
                        return try await adapter.useReset(account: account, credential: fresh, attemptID: attemptID)
                    }
                }
                return .outcome(outcome)
            case .failure(let error):
                return classifyReset(error)
            }
        } catch {
            return classifyReset(error)
        }
    }

    private static func isAuthRejection(_ error: any Error) -> Bool {
        switch error {
        case UsageError.needsLogin, UsageError.redirect: return true
        default: return false
        }
    }

    /// Maps a reset failure onto the provider-neutral result. Strings that can
    /// reach the screen are redacted here as well as in the adapter.
    private func classifyReset(_ error: any Error) -> ResetResult {
        switch error {
        case UsageError.needsLogin, UsageError.redirect:
            return .needsLogin
        case UsageError.forbidden(let reason):
            return .forbidden(reason: Redactor.redact(reason))
        case UsageError.rateLimited(let retryAfter):
            guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return .rateLimited(until: nil) }
            return .rateLimited(until: clock.now().addingTimeInterval(min(retryAfter, BackoffPolicy.rateLimitCap)))
        case UsageError.httpStatus(let status):
            return .providerError(status: status)
        case UsageError.invalidResponse, UsageError.tooLarge:
            return .unexpected
        case UsageError.transport, is PollTimeoutError, is CancellationError:
            return .unreachable
        case is ResetUnsupportedError:
            return .unsupported
        default:
            return .unexpected
        }
    }

    /// The one usage read after a reset: this account only, through the same
    /// fetch path a cycle uses, and never inside a backoff horizon. A poll's
    /// read of the account in flight is waited out first; when a read that
    /// started after the reset finished (`completedAt`) has succeeded, the
    /// row already holds post-reset numbers and nothing more is sent.
    private func readUsageAfterReset(_ accountID: UUID, provider: Provider, completedAt: Int) async {
        // Looked up again so a rename or move during the reset is honoured.
        guard let account = await storedAccount(accountID), let adapter = providers[provider] else { return }
        await waitForReadInFlight(accountID)
        if (lastSuccessfulRead[accountID] ?? 0) > completedAt {
            await diagnose(account, provider: provider, at: clock.now(),
                           message: "Usage read after reset skipped; a poll already read it after the reset")
            return
        }
        let attemptAt = clock.now()
        if let until = backoff.shouldSkip(account: accountID, provider: provider, now: attemptAt) {
            await diagnose(
                account,
                provider: provider,
                at: attemptAt,
                message: "Usage read after reset skipped; backing off until \(until.formatted(.iso8601))"
            )
            return
        }
        _ = await fetchAndRecord(account, adapter: adapter, provider: provider, attemptAt: attemptAt, onlyIfStillStored: true)
    }

    /// A diagnostics phrase for a reset result. Never carries an id or a body.
    private static func logDescription(of result: ResetResult) -> String {
        switch result {
        case .outcome(.reset): return "reset"
        case .outcome(.nothingToReset): return "nothing to reset"
        case .outcome(.noCredit): return "no credit"
        case .outcome(.cooldown(let until)): return "cooldown until \(until.map { $0.formatted(.iso8601) } ?? "unknown")"
        case .outcome(.notAvailable): return "not available"
        case .outcome(.unexpected): return "unexpected answer"
        case .rateLimited(let until): return "rate limited until \(until.map { $0.formatted(.iso8601) } ?? "unknown")"
        case .needsLogin: return "needs login"
        case .forbidden(let reason): return "forbidden: \(reason)"
        case .providerError(let status): return "provider error HTTP \(status)"
        case .unreachable: return "unreachable"
        case .unexpected: return "unexpected reply"
        case .unsupported: return "unsupported"
        case .alreadyRunning: return "already running"
        }
    }

    /// Maps a failure onto an `AccountState`, a backoff outcome, and a cache
    /// entry. Every string that can reach the screen passes through `Redactor`.
    private func record(error: Error, for account: Account, provider: Provider, attemptAt: Date) async {
        let now = clock.now()
        switch error {
        case UsageError.needsLogin:
            backoff.record(outcome: .needsLogin, for: account.id, provider: provider, now: now)
            await cache.recordFailure(
                account: account,
                state: .needsLogin,
                error: "Sign in again to resume updates",
                at: attemptAt,
                markStale: true
            )
            await diagnose(account, provider: provider, at: now, message: "Marked needs-login")

        case UsageError.forbidden(let reason):
            // The provider already redacted `reason`; redact again here so the
            // scheduler never depends on an adapter having done it.
            let reason = Redactor.redact(reason)
            let until = backoff.record(outcome: .forbidden, for: account.id, provider: provider, now: now)
                ?? now.addingTimeInterval(BackoffPolicy.forbiddenHold)
            await cache.recordFailure(
                account: account,
                state: .forbidden(reason),
                error: reason,
                at: attemptAt,
                markStale: true,
                nextAttemptAt: until
            )
            await diagnose(
                account,
                provider: provider,
                at: now,
                message: "Forbidden by organization; holding until \(until.formatted(.iso8601))"
            )

        case UsageError.rateLimited(let retryAfter):
            let until = backoff.record(outcome: .rateLimited(retryAfter: retryAfter), for: account.id, provider: provider, now: now)
                ?? now.addingTimeInterval(BackoffPolicy.rateLimitBase)
            persistBackoffIfChanged()
            await cache.recordFailure(
                account: account,
                state: .rateLimited(until: until),
                error: "Rate limited by \(provider.displayName)",
                at: attemptAt,
                markStale: false,
                nextAttemptAt: until
            )
            await diagnose(
                account,
                provider: provider,
                at: now,
                retryAfterSeconds: retryAfter.map { Int($0.rounded()) },
                message: "Rate limited; skipping until \(until.formatted(.iso8601))"
            )

        default:
            let message = Self.message(for: error)
            let until = backoff.record(outcome: .failure, for: account.id, provider: provider, now: now)
            if error is PollTimeoutError {
                logger.error("Fetch for account \(account.id.uuidString, privacy: .public) abandoned: \(message, privacy: .public)")
            }
            await cache.recordFailure(
                account: account,
                state: .error(message),
                error: message,
                at: attemptAt,
                markStale: true,
                nextAttemptAt: until
            )
            await diagnose(
                account,
                provider: provider,
                at: now,
                message: "\(message); backing off until \(until.map { $0.formatted(.iso8601) } ?? "next cycle")"
            )
        }
    }

    /// One `scheduler` line in the diagnostics log for a failed attempt. The
    /// provider already logged the HTTP exchange itself; this records how the
    /// scheduler classified it.
    private func diagnose(
        _ account: Account,
        provider: Provider,
        at: Date,
        retryAfterSeconds: Int? = nil,
        message: String
    ) async {
        await diagnostics?.record(DiagnosticEvent(
            ts: at,
            provider: provider,
            accountID: account.id,
            kind: .scheduler,
            retryAfterSeconds: retryAfterSeconds,
            message: message
        ))
    }

    private static func message(for error: Error) -> String {
        let raw: String
        switch error {
        case let timeout as PollTimeoutError:
            raw = "Timed out after \(Int(timeout.seconds)) s"
        case UsageError.invalidResponse(let reason):
            raw = "Unusable response: \(reason)"
        case UsageError.redirect:
            raw = "Redirected to a login page"
        case UsageError.tooLarge:
            raw = "Response too large"
        case UsageError.transport(let underlying):
            raw = "Network error: \(underlying.localizedDescription)"
        default:
            raw = String(describing: error)
        }
        return Redactor.redact(raw)
    }

    /// Races `operation` against the clock and returns whichever finishes
    /// first; the loser is cancelled and its result discarded (ISC-97).
    ///
    /// The work runs in a detached task rather than a task-group child on
    /// purpose: a group waits for every child before it returns, so a fetch
    /// that ignores cancellation would hold the timeout path open for as long
    /// as it liked. Here the timer resumes the caller on the deadline whatever
    /// the work is doing. The abandoned work keeps running to completion in
    /// the background: a refresh in flight inside it still finishes and
    /// persists its rotated token (D-7), and its status, arriving after the
    /// deadline, is dropped rather than recorded.
    ///
    /// Cancelling the caller (the cycle deadline, `stop()`) cancels both the
    /// work and the timer and throws `CancellationError`.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = clock
        let race = FirstWins<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.arm(continuation)
                let work = Task.detached {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task.detached {
                    do {
                        try await clock.sleep(for: seconds)
                        race.finish(.failure(PollTimeoutError(seconds: seconds)))
                    } catch {
                        // Cancelled because the work won or the caller left.
                    }
                }
                race.attach(work: work, timer: timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// Resumes one continuation with the first result offered and cancels the two
/// tasks in the race as soon as it is decided. Every later result is dropped.
private final class FirstWins<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func arm(_ continuation: CheckedContinuation<T, any Error>) {
        let pending: Result<T, any Error>? = state.withLock { s in
            if let result = s.result { return result }
            s.continuation = continuation
            return nil
        }
        // `finish` ran before `arm` (a cancellation that landed first).
        if let pending { continuation.resume(with: pending) }
    }

    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let alreadyDecided: Bool = state.withLock { s in
            s.work = work
            s.timer = timer
            return s.result != nil
        }
        if alreadyDecided {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, work, timer): (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?) =
            state.withLock { s in
                guard s.result == nil else { return (nil, nil, nil) }
                s.result = result
                let continuation = s.continuation
                s.continuation = nil
                return (continuation, s.work, s.timer)
            }
        continuation?.resume(with: result)
        work?.cancel()
        timer?.cancel()
    }
}

/// The only AppKit-facing piece of the scheduler: two notification observers,
/// removed on deinit. Kept apart from the actor so the actor is testable with
/// direct calls to `handleWillSleep()` and `handleDidWake()`, and so the AppKit
/// dependency is one class wide.
final class SleepWakeObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(
        center: NotificationCenter,
        onSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) {
        self.center = center
        tokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                onSleep()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                onWake()
            },
        ]
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
