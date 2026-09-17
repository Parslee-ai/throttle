import XCTest
@testable import Throttle

/// The retry-now override: a user who believes the provider's `Retry-After`
/// is stale can clear the horizon and fetch at once. The cleared state is
/// written to disk so a relaunch does not restore the old horizon.
final class RetryNowTests: XCTestCase {
    private var fixtures: [PollingFixture] = []
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    private func makeFixture(_ settings: PollSettings = PollSettings()) -> PollingFixture {
        let fixture = PollingFixture(settings: settings)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: BackoffPolicy

    func testClearHorizonDropsTheProviderHorizonAndStreak() {
        var policy = BackoffPolicy()
        let a = UUID()
        policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        XCTAssertNotNil(policy.shouldSkip(account: a, provider: .anthropic, now: t0))

        policy.clearHorizon(provider: .anthropic)
        XCTAssertNil(policy.shouldSkip(account: a, provider: .anthropic, now: t0))
        XCTAssertEqual(policy.providerHorizons(now: t0), [:])

        let next = policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        XCTAssertEqual(next?.timeIntervalSince(t0), BackoffPolicy.rateLimitBase, "the doubling streak restarts")
    }

    func testClearHorizonAlsoDropsListedAccountHorizonsButNotErrorBackoff() {
        var policy = BackoffPolicy()
        let a = UUID()
        let b = UUID()
        policy.record(outcome: .rateLimited(retryAfter: 900), for: a, provider: .openai, now: t0)
        policy.record(outcome: .rateLimited(retryAfter: 900), for: b, provider: .openai, now: t0)
        policy.record(outcome: .failure, for: a, provider: .openai, now: t0)

        policy.clearHorizon(provider: .openai, accounts: [a])
        XCTAssertNil(policy.rateLimitedUntil(account: a, provider: .openai, now: t0))
        XCTAssertEqual(policy.shouldSkip(account: a, provider: .openai, now: t0)?.timeIntervalSince(t0), BackoffPolicy.errorBase, "error backoff is untouched")
        XCTAssertEqual(policy.rateLimitedUntil(account: b, provider: .openai, now: t0)?.timeIntervalSince(t0), 900, "an unlisted account keeps its horizon")
    }

    // MARK: PollScheduler

    func testRetryProviderFetchesInsideTheHorizonAndClearsTheFile() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let a2 = try await f.addAccount(.anthropic, email: "a2@example.com")
        f.anthropic.script([.fail(.rateLimited(retryAfter: 3_600)), .succeed(usedPercent: 7)], for: a1)
        let start = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        XCTAssertEqual(f.anthropic.fetchCount, 1)
        XCTAssertEqual(try BackoffPersistence.decode(try Data(contentsOf: f.rateLimitsFile)), [.anthropic: start.addingTimeInterval(3_600)])

        // A plain refresh inside the horizon still skips (ISC-101).
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 1, "refreshNow honours the horizon")
        let skipped = try await f.requireEntry(a1)
        XCTAssertEqual(skipped.status.state, .rateLimited(until: start.addingTimeInterval(3_600)))

        await f.scheduler.retryProvider(.anthropic)
        await f.clock.advance(by: 10)
        await f.waitForCycles(3)
        XCTAssertEqual(f.anthropic.fetchCount, 3, "both Anthropic accounts are fetched after the override")
        let a1Entry = try await f.requireEntry(a1)
        XCTAssertEqual(a1Entry.status.state, .ok)
        XCTAssertEqual(a1Entry.status.windows.first?.usedPercent, 7)
        let a2Entry = try await f.requireEntry(a2)
        XCTAssertEqual(a2Entry.status.state, .ok)

        XCTAssertEqual(try BackoffPersistence.decode(try Data(contentsOf: f.rateLimitsFile)), [:], "the cleared horizon is persisted")
    }

    func testRetryProviderClearsTheFileEvenWhenTheProviderThrottlesAgain() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        f.anthropic.script([.fail(.rateLimited(retryAfter: 3_600)), .fail(.rateLimited(retryAfter: 60))], for: a1)
        let start = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)

        await f.clock.advance(by: 100)
        await f.scheduler.retryProvider(.anthropic)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2)
        let entry = try await f.requireEntry(a1)
        XCTAssertEqual(entry.status.state, .rateLimited(until: start.addingTimeInterval(170)), "a fresh horizon from the new Retry-After, not the old one")
        XCTAssertEqual(try BackoffPersistence.decode(try Data(contentsOf: f.rateLimitsFile)), [.anthropic: start.addingTimeInterval(170)])
    }

    func testRetryProviderClearsPerAccountHorizonsForOpenAI() async throws {
        let f = makeFixture()
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        f.openai.script([.fail(.rateLimited(retryAfter: 3_600)), .succeed(usedPercent: 4)], for: o1)

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        XCTAssertEqual(f.openai.fetchCount, 1)

        await f.scheduler.retryProvider(.openai)
        await f.waitForCycles(2)
        XCTAssertEqual(f.openai.fetchCount, 2)
        let entry = try await f.requireEntry(o1)
        XCTAssertEqual(entry.status.state, .ok)
    }

    func testRetryProviderLeavesTheOtherProviderAlone() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        f.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 3_600)), for: a1)
        f.openai.setBehavior(.fail(.rateLimited(retryAfter: 3_600)), for: o1)
        let start = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)

        await f.scheduler.retryProvider(.openai)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 1, "Anthropic stays under its horizon")
        XCTAssertEqual(f.openai.fetchCount, 2)
        let entry = try await f.requireEntry(a1)
        XCTAssertEqual(entry.status.state, .rateLimited(until: start.addingTimeInterval(3_600)))
    }
}
