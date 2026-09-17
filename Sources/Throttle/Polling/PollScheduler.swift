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
        backoff: BackoffPolicy = BackoffPolicy()
    ) {
        self.store = store
        self.providers = providers
        self.resolver = resolver
        self.cache = cache
        self.settings = settings
        self.clock = clock
        self.backoff = backoff
    }

    // MARK: Lifecycle

    /// Runs one cycle now and another every `pollInterval`. Calling it while
    /// running is a no-op.
    func start() {
        guard loopTask == nil else { return }
        isPausedForSleep = false
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
            let rateLimited = backoff.rateLimitedUntil(account: account.id, provider: provider, now: attemptAt) != nil
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
            await cache.recordSuccess(status, at: attemptAt)
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

        case UsageError.rateLimited(let retryAfter):
            let until = backoff.record(outcome: .rateLimited(retryAfter: retryAfter), for: account.id, provider: provider, now: now)
                ?? now.addingTimeInterval(BackoffPolicy.rateLimitBase)
            await cache.recordFailure(
                account: account,
                state: .rateLimited(until: until),
                error: "Rate limited by \(provider.displayName)",
                at: attemptAt,
                markStale: false,
                nextAttemptAt: until
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
        }
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

    /// Races `operation` against the clock. The loser is cancelled. The
    /// resolver's refresh ignores that cancellation by contract, so a timeout
    /// here never half-applies a token rotation.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: seconds)
                throw PollTimeoutError(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
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
