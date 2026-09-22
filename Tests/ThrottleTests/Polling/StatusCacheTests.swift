import XCTest
@testable import Throttle

final class StatusCacheTests: XCTestCase {
    private var clock: TestClock!
    private var cache: StatusCache!
    private let account = Account(provider: .anthropic, email: "cache@example.com", sortIndex: 0)

    override func setUp() {
        clock = TestClock()
        cache = StatusCache(clock: clock, staleAfter: 600)
    }

    private func status(percent: Double, at date: Date) -> AccountStatus {
        AccountStatus(
            accountID: account.id,
            provider: .anthropic,
            email: account.email,
            windows: [UsageWindow(key: "5h", label: "5h", usedPercent: percent, resetsAt: nil, durationSeconds: 18_000)],
            fetchedAt: date,
            state: .ok
        )
    }

    func testPlanLabelSurvivesAFailedAttempt() async {
        let now = clock.now()
        let withPlan = AccountStatus(
            accountID: account.id, provider: .anthropic, email: account.email,
            windows: [UsageWindow(key: "5h", label: "5h", usedPercent: 1, resetsAt: nil, durationSeconds: 18_000)],
            fetchedAt: now, state: .ok, planLabel: "max"
        )
        await cache.recordSuccess(withPlan, at: now)
        await cache.recordFailure(account: account, state: .error("boom"), error: "boom", at: now.addingTimeInterval(1), markStale: true)
        let entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.planLabel, "max")
    }

    func testResetCreditCountSurvivesAFailedAttemptAndASkip() async {
        let now = clock.now()
        let withCredits = AccountStatus(
            accountID: account.id, provider: .anthropic, email: account.email,
            windows: [UsageWindow(key: "7d", label: "Weekly", usedPercent: 1, resetsAt: nil, durationSeconds: 604_800)],
            fetchedAt: now, state: .ok, resetCreditsAvailable: 2
        )
        await cache.recordSuccess(withCredits, at: now)
        await cache.recordFailure(account: account, state: .error("boom"), error: "boom", at: now.addingTimeInterval(1), markStale: true)
        var entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.resetCreditsAvailable, 2)

        await cache.recordSkipped(account: account, until: now.addingTimeInterval(600), rateLimited: true, at: now.addingTimeInterval(2))
        entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.resetCreditsAvailable, 2)
    }

    func testSuccessIsCurrent() async {
        let now = clock.now()
        await cache.recordSuccess(status(percent: 40, at: now), at: now)
        let entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.isStale, false)
        XCTAssertEqual(entry?.lastGoodWindows?.first?.usedPercent, 40)
        XCTAssertNil(entry?.lastError)
        XCTAssertNil(entry?.nextAttemptAt)
    }

    func testFailureKeepsLastGoodWindowsAndFetchedAtAndMarksStale() async {
        let t0 = clock.now()
        await cache.recordSuccess(status(percent: 40, at: t0), at: t0)
        let t1 = t0.addingTimeInterval(300)
        await cache.recordFailure(account: account, state: .error("boom"), error: "boom", at: t1, markStale: true, nextAttemptAt: t1.addingTimeInterval(60))
        let entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.windows.first?.usedPercent, 40)
        XCTAssertEqual(entry?.status.fetchedAt, t0)
        XCTAssertEqual(entry?.status.state, .error("boom"))
        XCTAssertEqual(entry?.isStale, true)
        XCTAssertEqual(entry?.lastAttempt, t1)
        XCTAssertEqual(entry?.lastError, "boom")
        XCTAssertEqual(entry?.nextAttemptAt, t1.addingTimeInterval(60))
    }

    func testFailureBeforeAnySuccessHasNoLastGoodWindows() async {
        let now = clock.now()
        await cache.recordFailure(account: account, state: .needsLogin, error: nil, at: now, markStale: true)
        let entry = await cache.entry(for: account.id)
        XCTAssertNil(entry?.lastGoodWindows)
        XCTAssertEqual(entry?.status.windows, [])
        XCTAssertEqual(entry?.status.fetchedAt, now)
        XCTAssertEqual(entry?.status.state, .needsLogin)
    }

    func testStaleAfterTwiceTheIntervalByAgeAlone() async {
        let t0 = clock.now()
        await cache.recordSuccess(status(percent: 10, at: t0), at: t0)
        await clock.advance(by: 600)
        var entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.isStale, false, "exactly 2 x interval is still current")
        await clock.advance(by: 1)
        entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.isStale, true)
        let snapshot = await cache.snapshot()
        XCTAssertEqual(snapshot[account.id]?.isStale, true)
    }

    func testSkippedForRateLimitShowsHorizonAndState() async {
        let t0 = clock.now()
        await cache.recordSuccess(status(percent: 10, at: t0), at: t0)
        let until = t0.addingTimeInterval(900)
        await cache.recordSkipped(account: account, until: until, rateLimited: true, at: t0.addingTimeInterval(300))
        let entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.state, .rateLimited(until: until))
        XCTAssertEqual(entry?.nextAttemptAt, until)
        XCTAssertEqual(entry?.status.windows.first?.usedPercent, 10)
        XCTAssertEqual(entry?.isStale, false, "rate-limited data is only dimmed by age")
    }

    func testSkippedForErrorBackoffKeepsErrorState() async {
        let t0 = clock.now()
        await cache.recordFailure(account: account, state: .error("boom"), error: "boom", at: t0, markStale: true)
        let until = t0.addingTimeInterval(120)
        await cache.recordSkipped(account: account, until: until, rateLimited: false, at: t0.addingTimeInterval(60))
        let entry = await cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.state, .error("boom"))
        XCTAssertEqual(entry?.nextAttemptAt, until)
    }

    func testRetainDropsRemovedAccounts() async {
        let other = Account(provider: .openai, email: "other@example.com", sortIndex: 1)
        let now = clock.now()
        await cache.recordSuccess(status(percent: 1, at: now), at: now)
        await cache.recordFailure(account: other, state: .needsLogin, error: nil, at: now, markStale: true)
        await cache.retain(accountIDs: [account.id])
        let snapshot = await cache.snapshot()
        XCTAssertEqual(Set(snapshot.keys), [account.id])
    }

    func testUpdatesStreamYieldsCurrentSnapshotThenChanges() async {
        let now = clock.now()
        await cache.recordSuccess(status(percent: 5, at: now), at: now)
        let stream = await cache.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?[account.id]?.status.windows.first?.usedPercent, 5)
        await cache.recordSuccess(status(percent: 50, at: now), at: now)
        let second = await iterator.next()
        XCTAssertEqual(second?[account.id]?.status.windows.first?.usedPercent, 50)
    }
}
