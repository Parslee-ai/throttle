import XCTest
@testable import Throttle

/// The wait before the one read after a reset. A provider answers `reset`
/// before its usage endpoint shows it; a read in the same second still showed
/// the spent numbers. The scheduler waits `postResetReadDelay` on its clock,
/// then reads that account once. These tests drive the wait with the test
/// clock, so none of them waits on wall time.
final class PostResetReadDelayTests: XCTestCase {
    private var fixtures: [PollingFixture] = []
    private let delay = PollScheduler.postResetReadDelay

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    /// No stagger, so a cycle a test starts mid-wait never needs the clock.
    private func makeFixture() -> PollingFixture {
        let fixture = PollingFixture(settings: PollSettings(stagger: 0), postResetReadDelay: PollScheduler.postResetReadDelay)
        fixtures.append(fixture)
        return fixture
    }

    func testTheDelayIsFiveSeconds() {
        XCTAssertEqual(PollScheduler.postResetReadDelay, 5)
    }

    /// No read before the wait ends, exactly one after it, and a second
    /// reset during the wait is still refused without a request.
    func testTheReadWaitsForTheDelayThenRunsOnce() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.script([.succeed(usedPercent: 100), .succeed(usedPercent: 0)], for: account)
        await f.pollOnceThenStop()
        f.openai.scriptResets([.answer(.reset)], for: account)
        let answeredAt = f.clock.now()
        let parkedBefore = f.clock.parkedCount(interval: delay)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        let deadline = await f.clock.parkedSleep(interval: delay, number: parkedBefore + 1)

        XCTAssertEqual(deadline.seconds(after: answeredAt), delay, "the wait starts when the answer lands")
        XCTAssertEqual(f.openai.resetCount, 1)
        XCTAssertEqual(f.openai.fetchCount(for: account), 1, "no read before the wait ends")
        let inFlight = await f.scheduler.isResetInFlight(account.id)
        XCTAssertTrue(inFlight, "the account's reset is still running through the wait")
        let second = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(f.openai.resetCount, 1, "a second reset during the wait sends nothing")

        await f.clock.advance(by: delay - 0.5)
        XCTAssertEqual(f.openai.fetchCount(for: account), 1, "still no read half a second short")

        await f.clock.advance(by: 0.5)
        let result = await reset.value

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "exactly one read after the wait")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 0, "the settled reading")
        XCTAssertEqual(entry.status.fetchedAt.seconds(after: answeredAt), delay, "read when the wait ended")
        let stillRunning = await f.scheduler.isResetInFlight(account.id)
        XCTAssertFalse(stillRunning)
    }

    /// A 5xx may have spent the reset, so it is re-read too, after the same
    /// wait. An answer that changes nothing waits for nothing and reads
    /// nothing.
    func testOnlyAnswersThatWantAReadWait() async throws {
        let cases: [(MockUsageProvider.ResetBehavior, Bool)] = [
            (.fail(.httpStatus(503)), true),
            (.answer(.noCredit), true),
            (.answer(.nothingToReset), false),
            (.fail(.httpStatus(404)), false),
        ]
        for (behavior, reads) in cases {
            let f = makeFixture()
            let account = try await f.addAccount(.openai)
            f.openai.scriptResets([behavior], for: account)
            let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
            if reads {
                _ = await f.clock.parkedSleep(interval: delay, number: 1)
                XCTAssertEqual(f.openai.fetchCount, 0, "\(behavior): no read before the wait")
                await f.clock.advance(by: delay)
            }
            _ = await reset.value
            XCTAssertEqual(f.openai.fetchCount, reads ? 1 : 0, "\(behavior)")
            XCTAssertEqual(f.clock.parkedCount(interval: delay), reads ? 1 : 0, "\(behavior)")
        }
    }

    /// A backoff armed while the wait runs (here the account's own poll
    /// answered 429) still holds the read: the row keeps its last good
    /// reading with its age.
    func testABackoffArmedDuringTheWaitSkipsTheRead() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script(
            [.succeed(usedPercent: 100), .fail(.rateLimited(retryAfter: 1_800)), .succeed(usedPercent: 0)],
            for: account
        )
        await f.pollOnceThenStop()
        let before = try await f.requireEntry(account)
        f.anthropic.scriptResets([.answer(.reset)], for: account)
        let parkedBefore = f.clock.parkedCount(interval: delay)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        _ = await f.clock.parkedSleep(interval: delay, number: parkedBefore + 1)
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount(for: account), 2, "the poll during the wait was rate limited")

        await f.clock.advance(by: delay)
        let result = await reset.value

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.anthropic.fetchCount(for: account), 2, "no read inside the horizon")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after.status.windows, before.status.windows, "the last good reading stays")
    }

    /// A poll that reads the account successfully during the wait already
    /// holds post-reset numbers, so the read after the wait sends nothing.
    func testAPollDuringTheWaitStandsInForTheRead() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.script([.succeed(usedPercent: 100), .succeed(usedPercent: 0)], for: account)
        await f.pollOnceThenStop()
        f.openai.scriptResets([.answer(.reset)], for: account)
        let parkedBefore = f.clock.parkedCount(interval: delay)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        _ = await f.clock.parkedSleep(interval: delay, number: parkedBefore + 1)
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)

        await f.clock.advance(by: delay)
        _ = await reset.value

        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "the poll's read was the one read")
        XCTAssertEqual(f.openai.maxConcurrentFetches(for: account), 1)
    }
}

/// The row as the app shows it: the spinner stays through the wait and the
/// read, and the success note appears only when the fresh numbers do.
@MainActor
final class PostResetReadDelayModelTests: XCTestCase {
    private var harnesses: [ModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.cleanUp()
        }
        harnesses = []
    }

    func testTheSpinnerStaysUntilTheReadLandsAndTheNoteArrivesWithTheNumbers() async throws {
        let fixture = PollingFixture(settings: PollSettings(stagger: 0), postResetReadDelay: PollScheduler.postResetReadDelay)
        let h = ModelHarness(fixture: fixture)
        harnesses.append(h)
        let account = try await fixture.addAccount(.openai, email: "wait@example.com")
        fixture.openai.setResetCredits(1)
        fixture.openai.script([.succeed(usedPercent: 100), .succeed(usedPercent: 0)], for: account)
        await h.start()
        await h.stopPolling()
        fixture.openai.scriptResets([.answer(.reset)], for: account)
        let parkedBefore = fixture.clock.parkedCount(interval: PollScheduler.postResetReadDelay)

        h.model.useReset(account)
        let running = try XCTUnwrap(h.model.resetTasks[account.id])
        _ = await fixture.clock.parkedSleep(interval: PollScheduler.postResetReadDelay, number: parkedBefore + 1)

        XCTAssertTrue(h.model.resetsInFlight.contains(account.id), "the row still shows Resetting…")
        XCTAssertNil(h.model.resetNotices[account.id], "no note before the numbers")
        XCTAssertEqual(h.model.statuses[account.id]?.status.windows.first?.usedPercent, 100)

        await fixture.clock.advance(by: PollScheduler.postResetReadDelay)
        await running.value

        XCTAssertFalse(h.model.resetsInFlight.contains(account.id))
        XCTAssertEqual(h.model.resetNotices[account.id]?.text, ResetMessages.success)
        let entry = await fixture.cache.entry(for: account.id)
        XCTAssertEqual(entry?.status.windows.first?.usedPercent, 0, "the fresh numbers are in the cache the row reads")
    }
}
