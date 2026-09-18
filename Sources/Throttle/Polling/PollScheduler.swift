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

    /// Cycles that ran to completion or to their deadline. Tests wait on this.
    private(set) var completedCycles = 0
    /// Cycles that started. Differs from `completedCycles` only mid-cycle.
    private(set) var startedCycles = 0

    init(
        store: AccountStore,
        providers: [Provider: any UsageProvider],
        resolver: any CredentialResolving,
        cache: StatusCache,
        settings: PollSettings,
        clock: any PollClock,
        backoff: BackoffPolicy = BackoffPolicy(),
        backoffPersistence: BackoffPersistence? = nil,
        diagnostics: Diagnostics? = nil
    ) {
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

    private func cycleDidFinish() {
        cycleTask = nil
        completedCycles += 1
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

        let timeout = settings.perAccountTimeout
        let store = store
        let resolver = resolver
        do {
            let status = try await withTimeout(timeout) {
                let credential = try await resolver.validCredential(for: account, from: store, using: adapter)
                return try await adapter.fetchStatus(account: account, credential: credential)
            }
            backoff.record(outcome: .success, for: account.id, provider: provider, now: clock.now())
            persistBackoffIfChanged()
            await cache.recordSuccess(status, at: attemptAt)
            await diagnostics?.record(DiagnosticEvent(
                ts: clock.now(),
                provider: provider,
                accountID: account.id,
                kind: .usage,
                status: 200
            ))
        } catch is CancellationError {
            // The cycle deadline or stop() cancelled us. The deadline path
            // marks the account stale; stop() wants nothing recorded.
            return true
        } catch {
            if Task.isCancelled { return true }
            await record(error: error, for: account, provider: provider, attemptAt: attemptAt)
        }
        settledThisCycle.insert(account.id)
        return true
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
