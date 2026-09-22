import XCTest
@testable import Throttle

/// The scheduler times credential resolution and the usage read as one fetch.
/// The optional plan read after a good usage read must fit inside that same
/// budget, so it can never turn a good reading into "Timed out".
final class FetchBudgetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleFetchBudgetTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A usage read that takes most of the per-account budget, followed by a
    /// profile that never answers in time, still records `.ok` with its
    /// windows: the scheduler's real clock, timeout, and adapter together.
    func testSlowProfileAfterASlowUsageReadStillRecordsOK() async throws {
        let paths = AppPaths(applicationSupportDirectory: directory)
        let store = AccountStore(credentials: InMemoryCredentialStore(), paths: paths)
        let account = try await store.add(
            provider: .anthropic,
            email: "slow@example.com",
            credential: AccountCredential(accessToken: "t", scopes: ["user:profile", "user:inference"])
        )
        let clock = SystemClock()
        let cache = StatusCache(clock: clock, staleAfter: 600)
        let client = SlowProfileClient(
            usage: try AnthropicFixtures.data("anthropic-limits"),
            profile: try AnthropicFixtures.data("anthropic-profile"),
            usageDelay: 1.0,
            profileDelay: 30
        )
        let scheduler = PollScheduler(
            store: store,
            providers: [.anthropic: AnthropicProvider(client: client)],
            resolver: PassthroughCredentialResolver(),
            cache: cache,
            settings: PollSettings(perAccountTimeout: 1.6, cycleDeadline: 10, stagger: 0),
            clock: clock
        )

        await scheduler.refreshNow()
        var entry: CachedStatus?
        for _ in 0..<100 {
            entry = await cache.entry(for: account.id)
            if entry != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await scheduler.stop()

        let recorded = try XCTUnwrap(entry, "the cycle recorded the account")
        XCTAssertEqual(recorded.status.state, .ok, "not \(recorded.status.state)")
        XCTAssertEqual(recorded.status.windows.count, 4)
        XCTAssertFalse(recorded.isStale)
        XCTAssertNil(recorded.lastError)
        XCTAssertNil(recorded.status.planLabel, "the plan waits for a poll with time to spare")
    }

    func testBudgetIsUnboundOutsideAScheduledFetch() {
        XCTAssertNil(FetchBudget.remaining)
    }
}
