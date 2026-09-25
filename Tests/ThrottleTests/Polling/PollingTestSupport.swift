import Foundation
import os
import XCTest
@testable import Throttle

/// Counts every call and can succeed, fail, or hang per account. Hanging
/// waits on a cancellation-aware sleep that never elapses, so the scheduler's
/// timeout is what ends it.
final class MockUsageProvider: UsageProvider, @unchecked Sendable {
    enum Behavior {
        case succeed(usedPercent: Double)
        case fail(UsageError)
        case hang
        /// Ignores cancellation and keeps running on wall time for the given
        /// number of seconds, like a fetch stuck in a non-cooperative library.
        case ignoreCancellation(seconds: TimeInterval)
        /// Waits until the test calls `releaseFetches()`, then succeeds: a
        /// slow read the test ends when it chooses.
        case waitThenSucceed(usedPercent: Double)
        /// Succeeds with exactly these windows, for a row of a given shape.
        case succeedWindows([UsageWindow])
    }

    /// What a `refresh(credential:)` call does.
    enum RefreshBehavior {
        /// Rotates the pair at once.
        case rotate
        /// Waits until the test calls `releaseRefreshes()`, then rotates.
        case waitThenRotate
        case fail(UsageError)
    }

    struct Start: Equatable {
        let accountID: UUID
        let at: Date
    }

    /// What a `useReset` call does.
    enum ResetBehavior {
        case answer(ResetOutcome)
        case fail(UsageError)
        /// Waits until the test calls `releaseResets()`, then answers.
        case waitThenAnswer(ResetOutcome)
        /// Never answers; the scheduler's reset timeout ends it.
        case hang
    }

    /// One reset request as the provider saw it.
    struct ResetCall: Equatable {
        let accountID: UUID
        let attemptID: UUID
        let accessToken: String
    }

    private struct State {
        /// A script per account. The last element repeats forever.
        var scripts: [UUID: [Behavior]] = [:]
        var defaultBehavior: Behavior = .succeed(usedPercent: 25)
        var fetchCount = 0
        var refreshCount = 0
        var starts: [Start] = []
        var resetScripts: [UUID: [ResetBehavior]] = [:]
        var defaultResetBehavior: ResetBehavior = .answer(.reset)
        var resetCalls: [ResetCall] = []
        var resetWaiters: [CheckedContinuation<Void, Never>] = []
        var pendingResetReleases = 0
        /// When set, the reset count every successful fetch reports.
        var resetCredits: Int?
        var fetchWaiters: [CheckedContinuation<Void, Never>] = []
        var pendingFetchReleases = 0
        /// Reads running right now, per account, and the most ever seen.
        var fetchesInFlight: [UUID: Int] = [:]
        var maxConcurrentFetches: [UUID: Int] = [:]
        var refreshBehavior: RefreshBehavior = .rotate
        var refreshWaiters: [CheckedContinuation<Void, Never>] = []
        var pendingRefreshReleases = 0
        var fetchHook: (@Sendable (UUID, Int) async -> Void)?
        /// Tests suspended in one of the `waitFor…` calls below.
        var eventWaiters: [EventWaiter] = []
    }

    private struct EventWaiter {
        let ready: @Sendable (State) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    let provider: Provider
    private let clock: TestClock
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(provider: Provider, clock: TestClock) {
        self.provider = provider
        self.clock = clock
    }

    // MARK: Scripting

    func setBehavior(_ behavior: Behavior, for account: Account) {
        state.withLock { $0.scripts[account.id] = [behavior] }
    }

    /// Runs the behaviours in order; the last one repeats.
    func script(_ behaviors: [Behavior], for account: Account) {
        precondition(!behaviors.isEmpty)
        state.withLock { $0.scripts[account.id] = behaviors }
    }

    func setDefaultBehavior(_ behavior: Behavior) {
        state.withLock { $0.defaultBehavior = behavior }
    }

    /// Runs the reset behaviours in order; the last one repeats.
    func scriptResets(_ behaviors: [ResetBehavior], for account: Account) {
        precondition(!behaviors.isEmpty)
        state.withLock { $0.resetScripts[account.id] = behaviors }
    }

    func setRefreshBehavior(_ behavior: RefreshBehavior) {
        state.withLock { $0.refreshBehavior = behavior }
    }

    /// Runs at the start of every fetch with the account id and the fetch's
    /// number for that account (1-based), before the fetch answers.
    func onFetch(_ hook: @escaping @Sendable (UUID, Int) async -> Void) {
        state.withLock { $0.fetchHook = hook }
    }

    /// Lets one waiting `.waitThenSucceed` fetch answer.
    func releaseFetches() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            if s.fetchWaiters.isEmpty {
                s.pendingFetchReleases += 1
                return nil
            }
            return s.fetchWaiters.removeFirst()
        }
        waiter?.resume()
    }

    /// Lets one waiting `.waitThenRotate` refresh finish.
    func releaseRefreshes() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            if s.refreshWaiters.isEmpty {
                s.pendingRefreshReleases += 1
                return nil
            }
            return s.refreshWaiters.removeFirst()
        }
        waiter?.resume()
    }

    /// The reset count successful fetches report from now on.
    func setResetCredits(_ count: Int?) {
        state.withLock { $0.resetCredits = count }
    }

    /// Lets one waiting `.waitThenAnswer` reset answer (or the next one, if
    /// none is waiting yet).
    func releaseResets() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            if s.resetWaiters.isEmpty {
                s.pendingResetReleases += 1
                return nil
            }
            return s.resetWaiters.removeFirst()
        }
        waiter?.resume()
    }

    // MARK: Observation

    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var refreshCount: Int { state.withLock { $0.refreshCount } }
    var starts: [Start] { state.withLock { $0.starts } }
    func fetchCount(for account: Account) -> Int {
        state.withLock { $0.starts.filter { $0.accountID == account.id }.count }
    }
    var resetCalls: [ResetCall] { state.withLock { $0.resetCalls } }
    /// The most reads of one account that were ever running at once.
    func maxConcurrentFetches(for account: Account) -> Int {
        state.withLock { $0.maxConcurrentFetches[account.id] ?? 0 }
    }
    func fetchesInFlight(for account: Account) -> Int {
        state.withLock { $0.fetchesInFlight[account.id] ?? 0 }
    }
    var resetCount: Int { state.withLock { $0.resetCalls.count } }

    // MARK: Events

    /// Returns once `count` reset calls have reached the provider.
    func waitForResetCalls(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("\(count) reset call(s)", file: file, line: line) { $0.resetCalls.count >= count }
    }

    /// Returns once `count` refreshes have started.
    func waitForRefreshCalls(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("\(count) refresh call(s)", file: file, line: line) { $0.refreshCount >= count }
    }

    /// Returns once `count` `.waitThenSucceed` reads are parked, waiting for
    /// `releaseFetches()`.
    func waitForParkedFetches(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("\(count) parked read(s)", file: file, line: line) { $0.fetchWaiters.count >= count }
    }

    private func waitFor(
        _ description: String,
        file: StaticString,
        line: UInt,
        _ ready: @escaping @Sendable (State) -> Bool
    ) async {
        await awaitEvent(description, file: file, line: line) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = self.state.withLockUnchecked { s in
                    if ready(s) { return true }
                    s.eventWaiters.append(EventWaiter(ready: ready, continuation: continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    /// Resumes every waiter whose event has happened. Called after each
    /// change a waiter can observe.
    private func notifyWaiters() {
        let ready: [CheckedContinuation<Void, Never>] = state.withLockUnchecked { s in
            var fire: [CheckedContinuation<Void, Never>] = []
            var keep: [EventWaiter] = []
            for waiter in s.eventWaiters {
                if waiter.ready(s) {
                    fire.append(waiter.continuation)
                } else {
                    keep.append(waiter)
                }
            }
            s.eventWaiters = keep
            return fire
        }
        for continuation in ready { continuation.resume() }
    }

    // MARK: UsageProvider

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        let now = clock.now()
        let (behavior, number, hook): (Behavior, Int, (@Sendable (UUID, Int) async -> Void)?) = state.withLock { s in
            s.fetchCount += 1
            s.starts.append(Start(accountID: account.id, at: now))
            let running = (s.fetchesInFlight[account.id] ?? 0) + 1
            s.fetchesInFlight[account.id] = running
            s.maxConcurrentFetches[account.id] = max(s.maxConcurrentFetches[account.id] ?? 0, running)
            let number = s.starts.filter { $0.accountID == account.id }.count
            guard var script = s.scripts[account.id] else { return (s.defaultBehavior, number, s.fetchHook) }
            let next = script.removeFirst()
            if script.isEmpty { script = [next] }
            s.scripts[account.id] = script
            return (next, number, s.fetchHook)
        }
        defer { state.withLock { $0.fetchesInFlight[account.id, default: 1] -= 1 } }
        await hook?(account.id, number)
        switch behavior {
        case .waitThenSucceed(let usedPercent):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let released: Bool = state.withLock { s in
                    if s.pendingFetchReleases > 0 {
                        s.pendingFetchReleases -= 1
                        return true
                    }
                    s.fetchWaiters.append(continuation)
                    return false
                }
                if released { continuation.resume() } else { notifyWaiters() }
            }
            return AccountStatus(
                accountID: account.id,
                provider: provider,
                email: account.email,
                windows: [
                    UsageWindow(key: "5h", label: "5h", usedPercent: usedPercent, resetsAt: nil, durationSeconds: 18_000),
                ],
                fetchedAt: clock.now(),
                state: .ok,
                resetCreditsAvailable: state.withLock { $0.resetCredits }
            )
        case .succeed(let usedPercent):
            return AccountStatus(
                accountID: account.id,
                provider: provider,
                email: account.email,
                windows: [
                    UsageWindow(key: "5h", label: "5h", usedPercent: usedPercent, resetsAt: nil, durationSeconds: 18_000),
                ],
                fetchedAt: now,
                state: .ok,
                resetCreditsAvailable: state.withLock { $0.resetCredits }
            )
        case .succeedWindows(let windows):
            return AccountStatus(
                accountID: account.id,
                provider: provider,
                email: account.email,
                windows: windows,
                fetchedAt: now,
                state: .ok,
                resetCreditsAvailable: state.withLock { $0.resetCredits }
            )
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(365 * 86_400))
            throw UsageError.transport(URLError(.timedOut))
        case .ignoreCancellation(let seconds):
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                // `try?` swallows the CancellationError and keeps going.
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return AccountStatus(
                accountID: account.id,
                provider: provider,
                email: account.email,
                windows: [UsageWindow(key: "5h", label: "5h", usedPercent: 1, resetsAt: nil, durationSeconds: 18_000)],
                fetchedAt: now,
                state: .ok
            )
        }
    }

    /// Rotates the pair: a new access token with no expiry, so the refreshed
    /// credential is good until a provider rejects it.
    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        let (count, behavior): (Int, RefreshBehavior) = state.withLock { s in
            s.refreshCount += 1
            return (s.refreshCount, s.refreshBehavior)
        }
        notifyWaiters()
        switch behavior {
        case .rotate:
            break
        case .fail(let error):
            throw error
        case .waitThenRotate:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let released: Bool = state.withLock { s in
                    if s.pendingRefreshReleases > 0 {
                        s.pendingRefreshReleases -= 1
                        return true
                    }
                    s.refreshWaiters.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }
        var rotated = credential
        rotated.accessToken = "\(credential.accessToken)-r\(count)"
        rotated.expiresAt = nil
        return rotated
    }

    func useReset(account: Account, credential: AccountCredential, attemptID: UUID) async throws -> ResetOutcome {
        let behavior: ResetBehavior = state.withLock { s in
            s.resetCalls.append(ResetCall(accountID: account.id, attemptID: attemptID, accessToken: credential.accessToken))
            guard var script = s.resetScripts[account.id] else { return s.defaultResetBehavior }
            let next = script.removeFirst()
            if script.isEmpty { script = [next] }
            s.resetScripts[account.id] = script
            return next
        }
        notifyWaiters()
        switch behavior {
        case .answer(let outcome):
            return outcome
        case .fail(let error):
            throw error
        case .waitThenAnswer(let outcome):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let released: Bool = state.withLock { s in
                    if s.pendingResetReleases > 0 {
                        s.pendingResetReleases -= 1
                        return true
                    }
                    s.resetWaiters.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
            return outcome
        case .hang:
            try await Task.sleep(for: .seconds(365 * 86_400))
            throw UsageError.transport(URLError(.timedOut))
        }
    }
}

/// Everything a scheduler test needs, wired to a manual clock and a store
/// under a private temporary directory.
struct PollingFixture {
    let directory: URL
    let credentials: InMemoryCredentialStore
    let store: AccountStore
    let clock: TestClock
    let cache: StatusCache
    let anthropic: MockUsageProvider
    let openai: MockUsageProvider
    let scheduler: PollScheduler
    let settings: PollSettings
    /// The scheduler's credential resolver: a real `TokenRefresher` when
    /// `refreshingTokens`, else the passthrough.
    let resolver: any CredentialResolving
    /// True when the scheduler resolves credentials through a real
    /// `TokenRefresher` instead of the passthrough resolver.
    let refreshingTokens: Bool
    /// The scheduler's wait before the read after a reset. 0 unless a test
    /// is about that wait, so a reset returns without advancing the clock.
    let postResetReadDelay: TimeInterval

    /// A fresh fixture under its own temporary directory. With
    /// `refreshingTokens`, credentials go through a real `TokenRefresher`, so
    /// forced refreshes reach the mock's `refresh(credential:)`.
    /// `clock` defaults to a fixed start in the past; pass one started at
    /// the wall clock when a test compares scheduler times with `Date()`.
    /// `postResetReadDelay` is 0 by default; pass
    /// `PollScheduler.postResetReadDelay` to test the wait itself.
    init(
        settings: PollSettings = PollSettings(),
        refreshingTokens: Bool = false,
        clock: TestClock = TestClock(),
        postResetReadDelay: TimeInterval = 0
    ) {
        self.init(
            settings: settings,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ThrottlePollingTests-\(UUID().uuidString)", isDirectory: true),
            credentials: InMemoryCredentialStore(),
            clock: clock,
            refreshingTokens: refreshingTokens,
            postResetReadDelay: postResetReadDelay
        )
    }

    /// A second "launch" over the same directory, credentials, and clock, as
    /// if the app had quit and relaunched: new store, cache, mocks, scheduler.
    func relaunched() -> PollingFixture {
        PollingFixture(settings: settings, directory: directory, credentials: credentials, clock: clock,
                       refreshingTokens: refreshingTokens, postResetReadDelay: postResetReadDelay)
    }

    private init(
        settings: PollSettings,
        directory: URL,
        credentials: InMemoryCredentialStore,
        clock: TestClock,
        refreshingTokens: Bool,
        postResetReadDelay: TimeInterval
    ) {
        self.refreshingTokens = refreshingTokens
        self.postResetReadDelay = postResetReadDelay
        self.settings = settings
        self.directory = directory
        self.credentials = credentials
        self.clock = clock
        let paths = AppPaths(applicationSupportDirectory: directory)
        store = AccountStore(credentials: credentials, paths: paths)
        cache = StatusCache(clock: clock, staleAfter: settings.staleAfter)
        anthropic = MockUsageProvider(provider: .anthropic, clock: clock)
        openai = MockUsageProvider(provider: .openai, clock: clock)
        resolver = refreshingTokens
            ? TokenRefresher(now: { clock.now() }) as any CredentialResolving
            : PassthroughCredentialResolver()
        scheduler = PollScheduler(
            store: store,
            providers: [.anthropic: anthropic, .openai: openai],
            resolver: resolver,
            cache: cache,
            settings: settings,
            clock: clock,
            backoffPersistence: BackoffPersistence(paths: paths),
            postResetReadDelay: postResetReadDelay
        )
    }

    var rateLimitsFile: URL {
        AppPaths(applicationSupportDirectory: directory).rateLimitsFile
    }

    var startTime: Date { clock.now() }

    @discardableResult
    func addAccount(_ provider: Provider, email: String? = nil) async throws -> Account {
        let label = email ?? "\(provider.rawValue)-\(UUID().uuidString.prefix(6))@example.com"
        return try await store.add(
            provider: provider,
            email: label,
            credential: AccountCredential(accessToken: "token-\(label)", refreshToken: "refresh", expiresAt: nil)
        )
    }

    func mock(for provider: Provider) -> MockUsageProvider {
        provider == .anthropic ? anthropic : openai
    }

    var totalFetches: Int { anthropic.fetchCount + openai.fetchCount }

    func entry(_ account: Account) async -> CachedStatus? {
        await cache.entry(for: account.id)
    }

    /// `XCTUnwrap` cannot take an `await` in its autoclosure, so this does the
    /// unwrap after the hop.
    func requireEntry(_ account: Account, file: StaticString = #filePath, line: UInt = #line) async throws -> CachedStatus {
        let entry = await cache.entry(for: account.id)
        return try XCTUnwrap(entry, "no cache entry for \(account.email)", file: file, line: line)
    }

    /// Returns once the scheduler (the fixture's unless another is given)
    /// has completed `count` cycles, woken by the cycle's end itself.
    func waitForCycles(_ count: Int, on other: PollScheduler? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let scheduler = other ?? scheduler
        await awaitEvent("completed cycles == \(count)", file: file, line: line) {
            await scheduler.waitForCompletedCycles(count)
        }
    }

    /// Runs the first poll cycle, which `launch` starts, to its end, then
    /// leaves the clock 10 s past where it began.
    ///
    /// Each stagger sleep is woken only once it has parked on the clock, so
    /// the clock never moves before a sleep it is meant to wake. The first
    /// cycle has one stagger per account after the first of each provider:
    /// with no backoff saved, every account issues a read, and no read may
    /// wait on the clock.
    func runFirstCycle(
        on other: PollScheduler? = nil,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath,
        line: UInt = #line,
        launch: () async -> Void
    ) async {
        let stagger = settings.stagger
        let parkedBefore = clock.parkedCount(interval: stagger)
        let end = clock.now().addingTimeInterval(10)
        await launch()
        if stagger > 0 {
            let accounts = await store.accounts()
            let staggers = Dictionary(grouping: accounts, by: \.provider).values.reduce(0) { $0 + max(0, $1.count - 1) }
            for number in stride(from: 1, through: staggers, by: 1) {
                let deadline = await clock.parkedSleep(interval: stagger, number: parkedBefore + number, file: file, line: line)
                await clock.advance(to: deadline)
            }
        }
        await waitForCycles(1, on: other, file: file, line: line)
        await clock.advance(to: end)
    }

    /// Starts the scheduler, runs one cycle, and stops the timer.
    func pollOnceThenStop(file: StaticString = #filePath, line: UInt = #line) async {
        await runFirstCycle(file: file, line: line) { await scheduler.start() }
        await scheduler.stop()
    }

    func cleanUp() async {
        await scheduler.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` with sub-millisecond pauses until it holds. Fails the
/// test after about a second, which only happens when something is stuck.
func waitUntil(
    _ description: String,
    isolation: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    for _ in 0..<4_000 {
        if await condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000)
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
}

extension Date {
    /// Seconds after `reference`, rounded to the millisecond for assertions.
    func seconds(after reference: Date) -> Double {
        (timeIntervalSince(reference) * 1_000).rounded() / 1_000
    }
}
