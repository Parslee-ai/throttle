import AppKit
import XCTest
@testable import Throttle

/// Every test drives a `TestClock`; none waits on wall time. Fetch counts come
/// from `MockUsageProvider`, timing from the clock's recorded sleeps and the
/// mock's recorded start times.
final class PollSchedulerTests: XCTestCase {
    private var fixtures: [PollingFixture] = []

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

    // MARK: Cadence

    func testStartRunsOneCycleImmediatelyThenEveryInterval() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        try await f.addAccount(.openai)

        await f.scheduler.start()
        await f.waitForCycles(1)
        XCTAssertEqual(f.totalFetches, 2)

        await f.clock.advance(by: 299)
        await f.clock.settle()
        XCTAssertEqual(f.totalFetches, 2, "no cycle before the interval elapses")

        await f.clock.advance(by: 1)
        await f.waitForCycles(2)
        XCTAssertEqual(f.totalFetches, 4)

        let timerSleeps = f.clock.recordedSleeps.filter { $0.interval == 300 }
        XCTAssertEqual(timerSleeps.count, 2, "one timer sleep per completed tick plus the pending one")
    }

    func testStopCancelsTheTimer() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.stop()
        await f.clock.advance(by: 900)
        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1)
        XCTAssertEqual(f.clock.pendingSleepCount, 0)
    }

    func testUpdatingSettingsRestartsTheTimerWithoutAnExtraCycle() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        await f.scheduler.start()
        await f.waitForCycles(1)

        await f.scheduler.update(settings: PollSettings(pollInterval: 60))
        await f.clock.settle()
        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1, "changing the interval does not itself fetch")

        await f.clock.advance(by: 60)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2)
    }

    // MARK: Single-flight (ISC-98)

    func testTimerTickDuringSlowCycleIsDropped() async throws {
        let f = makeFixture(PollSettings(pollInterval: 60, perAccountTimeout: 100, cycleDeadline: 500))
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.hang, for: account)

        await f.scheduler.start()
        await waitUntil("first fetch started") { f.anthropic.fetchCount == 1 }

        await f.clock.advance(by: 60)
        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1, "the tick at 60 s found a cycle running and was dropped, not queued")
        XCTAssertEqual(f.anthropic.fetchCount, 1)

        f.anthropic.setBehavior(.succeed(usedPercent: 1), for: account)
        await f.clock.advance(by: 40)
        await f.waitForCycles(1)
        let afterTimeout = await f.scheduler.startedCycles
        XCTAssertEqual(afterTimeout, 1, "finishing the slow cycle does not replay the dropped tick")

        await f.clock.advance(by: 20)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 1, "the tick at 120 s ran but the timeout armed a 60 s backoff until 160 s")

        await f.clock.advance(by: 60)
        await f.waitForCycles(3)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the tick at 180 s fetches again")
    }

    // MARK: Stagger (ISC-96)

    func testSameProviderRequestsAreStaggeredWhileProvidersRunConcurrently() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let a2 = try await f.addAccount(.anthropic, email: "a2@example.com")
        let a3 = try await f.addAccount(.anthropic, email: "a3@example.com")
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        let o2 = try await f.addAccount(.openai, email: "o2@example.com")
        let t0 = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)

        let anthropicStarts = f.anthropic.starts
        XCTAssertEqual(anthropicStarts.map(\.accountID), [a1.id, a2.id, a3.id], "display order within a provider")
        XCTAssertEqual(anthropicStarts.map { $0.at.seconds(after: t0) }, [0, 2, 4])
        let openaiStarts = f.openai.starts
        XCTAssertEqual(openaiStarts.map(\.accountID), [o1.id, o2.id])
        XCTAssertEqual(openaiStarts.map { $0.at.seconds(after: t0) }, [0, 2], "OpenAI starts alongside Anthropic, not after it")

        let staggerSleeps = f.clock.recordedSleeps.filter { $0.interval == 2 }
        XCTAssertEqual(staggerSleeps.count, 3, "two gaps for three Anthropic accounts, one gap for two OpenAI accounts")
    }

    // MARK: Timeouts and deadline (ISC-97)

    func testPerAccountTimeoutMarksStaleAndKeepsLastGoodWindows() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.succeed(usedPercent: 40), for: account)
        let t0 = f.startTime

        await f.scheduler.start()
        await f.waitForCycles(1)
        f.anthropic.setBehavior(.hang, for: account)

        await f.clock.advance(by: 300)
        await waitUntil("second cycle in flight") { await f.scheduler.startedCycles == 2 }
        await f.clock.advance(by: 15)
        await f.waitForCycles(2)

        let entry = try await f.requireEntry(account)
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.lastGoodWindows?.first?.usedPercent, 40)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 40, "the row still draws the last good numbers")
        XCTAssertEqual(entry.status.fetchedAt, t0, "fetchedAt is the last good fetch, so the UI can show its age")
        XCTAssertEqual(entry.lastAttempt.seconds(after: t0), 300)
        XCTAssertEqual(entry.status.state, .error("Timed out after 15 s"))
        XCTAssertEqual(entry.nextAttemptAt?.seconds(after: t0), 375, "a timeout arms the 60 s per-account backoff")
        XCTAssertEqual(f.anthropic.fetchCount, 2)
    }

    /// ISC-97: a fetch that ignores cancellation cannot hold the cycle open. The
    /// mock keeps running on wall time for 5 s; the cycle must settle as soon
    /// as the clock passes the 15 s per-account timeout, well inside that.
    func testUncooperativeFetchIsAbandonedOnTheTimeout() async throws {
        let f = makeFixture(PollSettings(pollInterval: 300, perAccountTimeout: 15, cycleDeadline: 60))
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.ignoreCancellation(seconds: 5), for: account)
        let t0 = f.startTime
        let wallStart = Date()

        await f.scheduler.start()
        await waitUntil("fetch started") { f.anthropic.fetchCount == 1 }
        await f.clock.advance(by: 15)
        await f.waitForCycles(1)

        XCTAssertLessThan(Date().timeIntervalSince(wallStart), 4, "the cycle completed without waiting for the stuck fetch")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .error("Timed out after 15 s"))
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.lastAttempt, t0)
        XCTAssertNil(entry.lastGoodWindows, "the late result from the abandoned fetch is discarded, not recorded")
    }

    func testCycleDeadlineMarksUnfetchedAccountsStaleWithoutRequests() async throws {
        let f = makeFixture(PollSettings(pollInterval: 300, perAccountTimeout: 15, cycleDeadline: 40))
        var accounts: [Account] = []
        for index in 0..<4 {
            let account = try await f.addAccount(.anthropic, email: "a\(index)@example.com")
            f.anthropic.setBehavior(.hang, for: account)
            accounts.append(account)
        }
        let t0 = f.startTime

        await f.scheduler.start()
        // a0 starts at 0 and times out at 15; a1 starts at 17, times out at 32;
        // a2 starts at 34 and is cut off by the deadline at 40; a3 never starts.
        await f.clock.advance(by: 40)
        await f.waitForCycles(1)

        XCTAssertEqual(f.anthropic.starts.map { $0.at.seconds(after: t0) }, [0, 17, 34])
        XCTAssertEqual(f.anthropic.fetchCount, 3, "the fourth account never issued a request")

        let e0 = try await f.requireEntry(accounts[0])
        XCTAssertEqual(e0.status.state, .error("Timed out after 15 s"))
        let e2 = try await f.requireEntry(accounts[2])
        XCTAssertTrue(e2.isStale)
        XCTAssertEqual(e2.status.state, .error("Poll cycle timed out"))
        let e3 = try await f.requireEntry(accounts[3])
        XCTAssertTrue(e3.isStale)
        XCTAssertEqual(e3.status.state, .error("Poll cycle timed out"))
        XCTAssertEqual(e3.lastAttempt.seconds(after: t0), 40)
        XCTAssertNil(e3.nextAttemptAt, "an account the deadline skipped is not backed off; it was never asked")

        let cycleInFlight = await f.scheduler.isCycleInFlight
        XCTAssertFalse(cycleInFlight)
    }

    // MARK: Backoff (ISC-99, ISC-100)

    func testAnthropic429SkipsSiblingAnthropicAccountsWhileOpenAIStillFetches() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let a2 = try await f.addAccount(.anthropic, email: "a2@example.com")
        let a3 = try await f.addAccount(.anthropic, email: "a3@example.com")
        try await f.addAccount(.openai, email: "o1@example.com")
        try await f.addAccount(.openai, email: "o2@example.com")
        f.anthropic.script([.fail(.rateLimited(retryAfter: 600)), .succeed(usedPercent: 3)], for: a1)
        let t0 = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)

        XCTAssertEqual(f.anthropic.fetchCount, 1, "the 429 stopped the other two Anthropic requests")
        XCTAssertEqual(f.openai.fetchCount, 2, "OpenAI accounts fetched in the same cycle")
        for account in [a1, a2, a3] {
            let entry = try await f.requireEntry(account)
            XCTAssertEqual(entry.status.state, .rateLimited(until: t0.addingTimeInterval(600)), account.email)
            XCTAssertEqual(entry.nextAttemptAt, t0.addingTimeInterval(600), account.email)
            XCTAssertFalse(entry.isStale, "rate-limited rows are dimmed by age only")
        }

        await f.clock.advance(by: 300)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 1, "still inside the horizon at 300 s")
        XCTAssertEqual(f.openai.fetchCount, 4)

        await f.clock.advance(by: 300)
        await f.waitForCycles(3)
        XCTAssertEqual(f.anthropic.fetchCount, 4, "the horizon passed at 600 s, so all three fetched at 600 s")
        let recovered = try await f.requireEntry(a1)
        XCTAssertEqual(recovered.status.state, .ok)
    }

    func testAnthropic429WithoutRetryAfterUsesFiveMinutes() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.fail(.rateLimited(retryAfter: nil)), for: a1)
        let t0 = f.startTime

        await f.scheduler.start()
        await f.waitForCycles(1)
        let entry = try await f.requireEntry(a1)
        XCTAssertEqual(entry.status.state, .rateLimited(until: t0.addingTimeInterval(300)))
    }

    func testOpenAI429IsPerAccountOnly() async throws {
        let f = makeFixture()
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        let o2 = try await f.addAccount(.openai, email: "o2@example.com")
        f.openai.setBehavior(.fail(.rateLimited(retryAfter: 1_000)), for: o1)

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        XCTAssertEqual(f.openai.fetchCount(for: o1), 1)
        XCTAssertEqual(f.openai.fetchCount(for: o2), 1, "o2 fetched in the same cycle despite o1's 429")

        await f.clock.advance(by: 300)
        await f.waitForCycles(2)
        XCTAssertEqual(f.openai.fetchCount(for: o1), 1, "o1 skipped inside its horizon")
        XCTAssertEqual(f.openai.fetchCount(for: o2), 2)
    }

    func testServerErrorBackoffDoublesThenResetsOnSuccess() async throws {
        let f = makeFixture(PollSettings(pollInterval: 60))
        let account = try await f.addAccount(.openai)
        f.openai.script(
            [
                .fail(.transport(URLError(.networkConnectionLost))), // cycle 1 at 0   -> horizon 60
                .fail(.invalidResponse("HTTP 503")),                 // cycle 2 at 60  -> horizon 120 (skips the tick at 120)
                .succeed(usedPercent: 9),                            // cycle 4 at 180 -> reset
                .fail(.transport(URLError(.timedOut))),              // cycle 5 at 240 -> horizon back to 60
            ],
            for: account
        )
        let t0 = f.startTime

        await f.scheduler.start()
        await f.waitForCycles(1)
        var entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.nextAttemptAt?.seconds(after: t0), 60)
        XCTAssertEqual(entry.status.state, .error("Network error: \(URLError(.networkConnectionLost).localizedDescription)"))
        XCTAssertTrue(entry.isStale)

        await f.clock.advance(by: 60)
        await f.waitForCycles(2)
        entry = try await f.requireEntry(account)
        XCTAssertEqual(f.openai.fetchCount, 2)
        XCTAssertEqual(entry.nextAttemptAt?.seconds(after: t0), 180, "second consecutive failure doubles to 120 s")
        XCTAssertEqual(entry.status.state, .error("Unusable response: HTTP 503"))

        await f.clock.advance(by: 60)
        await f.waitForCycles(3)
        XCTAssertEqual(f.openai.fetchCount, 2, "skipped at 120 s")

        await f.clock.advance(by: 60)
        await f.waitForCycles(4)
        entry = try await f.requireEntry(account)
        XCTAssertEqual(f.openai.fetchCount, 3)
        XCTAssertEqual(entry.status.state, .ok)
        XCTAssertFalse(entry.isStale)
        XCTAssertNil(entry.nextAttemptAt)

        await f.clock.advance(by: 60)
        await f.waitForCycles(5)
        entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.nextAttemptAt?.seconds(after: t0), 300, "after a success the schedule restarts at 60 s")
        XCTAssertEqual(entry.lastGoodWindows?.first?.usedPercent, 9)
    }

    func testErrorMessagesAreRedacted() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.setBehavior(.fail(.invalidResponse("rejected Bearer \(FakeToken.anthropicBareSecret)")), for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .error("Unusable response: rejected [redacted]"))
        XCTAssertFalse(entry.lastError?.contains("secret") ?? true)
    }

    // MARK: Login state

    func testNeedsLoginKeepsTheRowAndLastGoodWindowsAndRetriesNextCycle() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script([.succeed(usedPercent: 70), .fail(.needsLogin)], for: account)

        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.clock.advance(by: 300)
        await f.waitForCycles(2)

        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .needsLogin)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 70)
        XCTAssertTrue(entry.isStale)
        XCTAssertNil(entry.nextAttemptAt, "needs-login arms no backoff")

        await f.clock.advance(by: 300)
        await f.waitForCycles(3)
        XCTAssertEqual(f.anthropic.fetchCount, 3, "retried each cycle so a re-login takes effect")
    }

    func testMissingCredentialBecomesNeedsLoginWithoutAFetch() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        let other = try await f.addAccount(.openai)
        try f.credentials.delete(for: account.id)

        await f.scheduler.start()
        await f.waitForCycles(1)

        XCTAssertEqual(f.anthropic.fetchCount, 0)
        XCTAssertEqual(f.openai.fetchCount, 1)
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .needsLogin)
        XCTAssertEqual(entry.status.email, account.email)
        let otherEntry = try await f.requireEntry(other)
        XCTAssertEqual(otherEntry.status.state, .ok)
        XCTAssertTrue(f.clock.recordedSleeps.allSatisfy { $0.interval != 2 }, "a skipped account adds no stagger")
    }

    // MARK: Forbidden by organization (D-33)

    private let orgRefusal = "OAuth authentication is currently not allowed for this organization."

    func testForbiddenIsItsOwnStateAndHoldsOnlyThatAccountFor24Hours() async throws {
        let f = makeFixture()
        let held = try await f.addAccount(.anthropic, email: "held@example.com")
        let sibling = try await f.addAccount(.anthropic, email: "sibling@example.com")
        f.anthropic.script([.succeed(usedPercent: 70), .fail(.forbidden(reason: orgRefusal))], for: held)

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        await f.clock.advance(by: 300)
        await f.waitForCycles(2)

        let entry = try await f.requireEntry(held)
        XCTAssertEqual(entry.status.state, .forbidden(orgRefusal))
        XCTAssertEqual(entry.lastError, orgRefusal)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 70, "the last good windows are kept")
        XCTAssertTrue(entry.isStale)
        let holdUntil = entry.lastAttempt.addingTimeInterval(BackoffPolicy.forbiddenHold)
        XCTAssertEqual(entry.nextAttemptAt, holdUntil)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 2)
        XCTAssertEqual(f.anthropic.fetchCount(for: sibling), 2)

        for cycle in 3...5 {
            await f.clock.advance(by: 300)
            await f.waitForCycles(cycle)
        }
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 2, "a held account is not fetched")
        XCTAssertEqual(f.anthropic.fetchCount(for: sibling), 5, "the hold is per account, not provider-wide")
        let skipped = try await f.requireEntry(held)
        XCTAssertEqual(skipped.status.state, .forbidden(orgRefusal), "skipping keeps the forbidden state on the row")
        XCTAssertEqual(skipped.nextAttemptAt, holdUntil)

        await f.scheduler.refreshNow()
        await f.waitForCycles(6)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 2, "refreshNow honours the hold")
    }

    func testRetryProviderLeavesAForbiddenAccountHeld() async throws {
        let f = makeFixture()
        let held = try await f.addAccount(.anthropic, email: "held@example.com")
        let limited = try await f.addAccount(.anthropic, email: "limited@example.com")
        f.anthropic.setBehavior(.fail(.forbidden(reason: orgRefusal)), for: held)
        f.anthropic.script([.fail(.rateLimited(retryAfter: 3_600)), .succeed(usedPercent: 5)], for: limited)

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 1)
        XCTAssertEqual(f.anthropic.fetchCount(for: limited), 1)

        // Under the provider-wide 429 the held row still says forbidden.
        await f.clock.advance(by: 300)
        await f.waitForCycles(2)
        let underThrottle = try await f.requireEntry(held)
        XCTAssertEqual(underThrottle.status.state, .forbidden(orgRefusal))

        await f.scheduler.retryProvider(.anthropic)
        await f.clock.advance(by: 10)
        await f.waitForCycles(3)
        XCTAssertEqual(f.anthropic.fetchCount(for: limited), 2, "the override lifts the rate-limit horizon")
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 1, "the override does not lift a forbidden hold")
        let limitedEntry = try await f.requireEntry(limited)
        XCTAssertEqual(limitedEntry.status.state, .ok)
        let heldEntry = try await f.requireEntry(held)
        XCTAssertEqual(heldEntry.status.state, .forbidden(orgRefusal))
    }

    func testForbiddenHoldEndsAfter24HoursAndASuccessClearsIt() async throws {
        let f = makeFixture(PollSettings(pollInterval: 1_800))
        let held = try await f.addAccount(.anthropic, email: "held@example.com")
        f.anthropic.script([.fail(.forbidden(reason: orgRefusal)), .succeed(usedPercent: 3)], for: held)

        await f.scheduler.start()
        await f.waitForCycles(1)
        let first = try await f.requireEntry(held)
        XCTAssertEqual(first.status.state, .forbidden(orgRefusal))

        // 47 half-hour ticks land inside the hold; the 48th is past it.
        await f.clock.advance(by: BackoffPolicy.forbiddenHold - 1_800)
        await f.waitForCycles(48)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 1, "no fetch inside the hold")

        await f.clock.advance(by: 1_800)
        await f.waitForCycles(49)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 2)
        let entry = try await f.requireEntry(held)
        XCTAssertEqual(entry.status.state, .ok)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 3)
        XCTAssertNil(entry.nextAttemptAt)

        await f.clock.advance(by: 1_800)
        await f.waitForCycles(50)
        XCTAssertEqual(f.anthropic.fetchCount(for: held), 3, "the hold is gone after the success")
    }

    // MARK: Refresh now (ISC-101)

    func testRefreshNowRunsACycleImmediatelyAndRespectsBackoff() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let a2 = try await f.addAccount(.anthropic, email: "a2@example.com")
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        f.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 900)), for: a1)
        let t0 = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        XCTAssertEqual(f.anthropic.fetchCount, 1)
        XCTAssertEqual(f.openai.fetchCount, 1)

        await f.scheduler.refreshNow()
        await f.clock.advance(by: 10)
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 1, "refresh now does not override the Anthropic horizon")
        XCTAssertEqual(f.openai.fetchCount, 2, "refresh now fetched the account that is allowed")
        let skipped = try await f.requireEntry(a2)
        XCTAssertEqual(skipped.status.state, .rateLimited(until: t0.addingTimeInterval(900)))
        _ = o1
    }

    // MARK: The provider horizon survives a relaunch (ISC-99)

    func testAnthropic429WritesTheProviderHorizonToDisk() async throws {
        let f = makeFixture()
        let a1 = try await f.addAccount(.anthropic, email: "a1@example.com")
        let o1 = try await f.addAccount(.openai, email: "o1@example.com")
        f.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 3_600)), for: a1)
        f.openai.setBehavior(.fail(.rateLimited(retryAfter: 3_600)), for: o1)
        let t0 = f.startTime

        await f.scheduler.start()
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)

        let data = try Data(contentsOf: f.rateLimitsFile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["anthropic"], "only the provider-wide horizon is stored; the OpenAI 429 is per account")
        XCTAssertEqual(object["anthropic"] as? String, t0.addingTimeInterval(3_600).formatted(.iso8601))
        XCTAssertEqual(try BackoffPersistence.decode(data), [.anthropic: t0.addingTimeInterval(3_600)])

        let attributes = try FileManager.default.attributesOfItem(atPath: f.rateLimitsFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRelaunchInsideTheHorizonSkipsAnthropicWithoutARequestUntilItPasses() async throws {
        let first = makeFixture()
        let a1 = try await first.addAccount(.anthropic, email: "a1@example.com")
        let a2 = try await first.addAccount(.anthropic, email: "a2@example.com")
        let o1 = try await first.addAccount(.openai, email: "o1@example.com")
        first.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 3_600)), for: a1)
        let t0 = first.startTime

        await first.scheduler.start()
        await first.clock.advance(by: 10)
        await first.waitForCycles(1)
        XCTAssertEqual(first.anthropic.fetchCount, 1)
        await first.scheduler.stop()

        // Quit and relaunch 20 minutes later: new scheduler, empty cache, same disk.
        await first.clock.advance(by: 1_200)
        let second = first.relaunched()
        try await second.store.load()

        await second.scheduler.start()
        await second.clock.advance(by: 10)
        await second.waitForCycles(1)
        XCTAssertEqual(second.anthropic.fetchCount, 0, "no Anthropic request on launch inside the saved horizon")
        XCTAssertEqual(second.openai.fetchCount, 1, "OpenAI is not under the Anthropic horizon")
        for account in [a1, a2] {
            let entry = try await second.requireEntry(account)
            XCTAssertEqual(entry.status.state, .rateLimited(until: t0.addingTimeInterval(3_600)), account.email)
            XCTAssertEqual(entry.nextAttemptAt, t0.addingTimeInterval(3_600), account.email)
        }
        let openai = try await second.requireEntry(o1)
        XCTAssertEqual(openai.status.state, .ok)

        // "Add account" calls refreshNow; it must not poke the endpoint either.
        await second.scheduler.refreshNow()
        await second.clock.advance(by: 10)
        await second.waitForCycles(2)
        XCTAssertEqual(second.anthropic.fetchCount, 0, "refresh now honours the restored horizon")

        // Once the horizon passes, the next cycle fetches and the file clears.
        await second.clock.advance(by: 3_600)
        await waitUntil("anthropic fetched after the horizon") { second.anthropic.fetchCount >= 2 }
        await waitUntil("rate-limit file cleared") {
            (try? BackoffPersistence.decode(Data(contentsOf: second.rateLimitsFile))) == [:]
        }
        await second.scheduler.stop()
    }

    func testRelaunchAfterTheHorizonIgnoresTheSavedValueAndFetches() async throws {
        let first = makeFixture()
        let a1 = try await first.addAccount(.anthropic, email: "a1@example.com")
        first.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 600)), for: a1)

        await first.scheduler.start()
        await first.clock.advance(by: 10)
        await first.waitForCycles(1)
        await first.scheduler.stop()

        await first.clock.advance(by: 601)
        let second = first.relaunched()
        try await second.store.load()
        await second.scheduler.start()
        await second.clock.advance(by: 10)
        await second.waitForCycles(1)
        XCTAssertEqual(second.anthropic.fetchCount, 1, "an expired horizon is ignored, so the launch cycle fetches")
        let entry = try await second.requireEntry(a1)
        XCTAssertEqual(entry.status.state, .ok)
        await second.scheduler.stop()
    }

    func testRefreshNowDuringACycleIsQueuedOnce() async throws {
        let f = makeFixture(PollSettings(pollInterval: 300, perAccountTimeout: 15, cycleDeadline: 60))
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script([.hang, .succeed(usedPercent: 1)], for: account)

        await f.scheduler.start()
        await waitUntil("first fetch started") { f.anthropic.fetchCount == 1 }
        await f.scheduler.refreshNow()
        await f.scheduler.refreshNow()
        await f.scheduler.refreshNow()
        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1, "nothing starts while a cycle is running")

        await f.clock.advance(by: 15)
        await f.waitForCycles(2)
        await f.clock.settle()
        let total = await f.scheduler.startedCycles
        XCTAssertEqual(total, 2, "three clicks during a cycle produce exactly one follow-up cycle")
        // The follow-up fetch is skipped: the timeout armed a 60 s backoff.
        XCTAssertEqual(f.anthropic.fetchCount, 1)
    }

    // MARK: Request budget (ISC-105)

    func testEightAccountsOverAnHourIssueAtMostNinetySixRequests() async throws {
        let f = makeFixture()
        for index in 0..<4 {
            try await f.addAccount(.anthropic, email: "a\(index)@example.com")
            try await f.addAccount(.openai, email: "o\(index)@example.com")
        }

        await f.scheduler.start()
        await f.clock.advance(by: 3_599)
        await f.waitForCycles(12)

        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 12)
        XCTAssertLessThanOrEqual(f.totalFetches, 96)
        XCTAssertEqual(f.totalFetches, 96, "every account fetched exactly once per cycle")
        XCTAssertEqual(f.anthropic.refreshCount + f.openai.refreshCount, 0, "the passthrough resolver never refreshes")
    }

    // MARK: Rotation independence (ISC-103)

    /// The 10 s menu bar rotation lives in `UI/` and reads `StatusCache` only.
    /// It has no handle on the scheduler, so the strongest thing to assert is
    /// that reading the cache, however often, reaches no provider.
    func testOneHundredSnapshotReadsTriggerZeroFetches() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        try await f.addAccount(.openai)
        await f.scheduler.start()
        await f.waitForCycles(1)
        let before = f.totalFetches

        for _ in 0..<100 {
            let snapshot = await f.cache.snapshot()
            XCTAssertEqual(snapshot.count, 2)
        }
        await f.clock.settle()

        XCTAssertEqual(f.totalFetches, before)
        XCTAssertEqual(before, 2)
    }

    // MARK: Staleness (ISC-104)

    func testStatusIsStaleAfterTwiceThePollInterval() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.stop()

        await f.clock.advance(by: 600)
        var entry = try await f.requireEntry(account)
        XCTAssertFalse(entry.isStale)
        await f.clock.advance(by: 1)
        entry = try await f.requireEntry(account)
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.status.state, .ok, "stale is a marker on good data, not an error")
    }

    // MARK: Sleep and wake (ISC-102)

    func testSleepPausesTheTimerAndWakeRunsACycleImmediately() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        await f.scheduler.start()
        await f.waitForCycles(1)

        await f.scheduler.handleWillSleep()
        await f.clock.advance(by: 900)
        var started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1, "no cycles while asleep")
        let running = await f.scheduler.isRunning
        XCTAssertTrue(running, "paused, not stopped")

        await f.scheduler.handleDidWake()
        await f.waitForCycles(2)
        started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 2, "wake ran a cycle without waiting for the clock")

        await f.clock.advance(by: 300)
        await f.waitForCycles(3)
    }

    func testSleepWakeObserverDrivesTheSchedulerThroughANotificationCenter() async throws {
        let f = makeFixture()
        try await f.addAccount(.openai)
        let center = NotificationCenter()
        await f.scheduler.observeSleepWake(center: center)
        await f.scheduler.start()
        await f.waitForCycles(1)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await waitUntil("paused for sleep") { await f.scheduler.isPausedForSleep }
        await f.clock.advance(by: 600)
        var started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 1)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await f.waitForCycles(2)
        started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 2)
        XCTAssertEqual(f.openai.fetchCount, 2)
    }

    func testWakeOnASchedulerThatWasNeverStartedDoesNothing() async throws {
        let f = makeFixture()
        try await f.addAccount(.openai)
        await f.scheduler.handleDidWake()
        await f.clock.settle()
        let started = await f.scheduler.startedCycles
        XCTAssertEqual(started, 0)
    }
}
