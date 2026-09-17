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
    }

    struct Start: Equatable {
        let accountID: UUID
        let at: Date
    }

    private struct State {
        /// A script per account. The last element repeats forever.
        var scripts: [UUID: [Behavior]] = [:]
        var defaultBehavior: Behavior = .succeed(usedPercent: 25)
        var fetchCount = 0
        var refreshCount = 0
        var starts: [Start] = []
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

    // MARK: Observation

    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var refreshCount: Int { state.withLock { $0.refreshCount } }
    var starts: [Start] { state.withLock { $0.starts } }
    func fetchCount(for account: Account) -> Int {
        state.withLock { $0.starts.filter { $0.accountID == account.id }.count }
    }

    // MARK: UsageProvider

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        let now = clock.now()
        let behavior: Behavior = state.withLock { s in
            s.fetchCount += 1
            s.starts.append(Start(accountID: account.id, at: now))
            guard var script = s.scripts[account.id] else { return s.defaultBehavior }
            let next = script.removeFirst()
            if script.isEmpty { script = [next] }
            s.scripts[account.id] = script
            return next
        }
        switch behavior {
        case .succeed(let usedPercent):
            return AccountStatus(
                accountID: account.id,
                provider: provider,
                email: account.email,
                windows: [
                    UsageWindow(key: "5h", label: "5h", usedPercent: usedPercent, resetsAt: nil, durationSeconds: 18_000),
                ],
                fetchedAt: now,
                state: .ok
            )
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(365 * 86_400))
            throw UsageError.transport(URLError(.timedOut))
        }
    }

    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        state.withLock { $0.refreshCount += 1 }
        return credential
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

    init(settings: PollSettings = PollSettings()) {
        self.settings = settings
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottlePollingTests-\(UUID().uuidString)", isDirectory: true)
        credentials = InMemoryCredentialStore()
        store = AccountStore(credentials: credentials, paths: AppPaths(applicationSupportDirectory: directory))
        clock = TestClock()
        cache = StatusCache(clock: clock, staleAfter: settings.staleAfter)
        anthropic = MockUsageProvider(provider: .anthropic, clock: clock)
        openai = MockUsageProvider(provider: .openai, clock: clock)
        scheduler = PollScheduler(
            store: store,
            providers: [.anthropic: anthropic, .openai: openai],
            resolver: PassthroughCredentialResolver(),
            cache: cache,
            settings: settings,
            clock: clock
        )
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

    /// Yields until `completedCycles` reaches `count`.
    func waitForCycles(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("completed cycles == \(count)", file: file, line: line) {
            await scheduler.completedCycles >= count
        }
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
