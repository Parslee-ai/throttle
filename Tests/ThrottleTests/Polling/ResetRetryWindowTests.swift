import XCTest
@testable import Throttle

/// The scheduler's rules for an attempt that went unanswered, for a provider
/// that names a retry window: retries only inside the window, measured from
/// the first send and checked before every send; a refused retry reported
/// as unexpected; a hold on new attempts until a read made after the close
/// succeeds; and a sign-in that retires the attempt.
final class ResetRetryWindowTests: XCTestCase {
    private var fixtures: [PollingFixture] = []
    private let window: TimeInterval = 600

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    private func makeFixture(refreshingTokens: Bool = false) -> PollingFixture {
        let fixture = PollingFixture(refreshingTokens: refreshingTokens)
        fixture.anthropic.setResetRetryWindow(window)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: The window

    /// A retry inside the window resends the same id and kind; the window is
    /// the first send's, so a second unanswered send does not extend it, and
    /// at its end the retry sends nothing and reads usage once.
    func testRetriesAreSentOnlyWithinTheWindowOfTheFirstSend() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502))], for: a)
        let id = UUID()
        let firstSend = f.clock.now()

        let first = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(first, .providerError(status: 502))
        let open = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertEqual(open, .retryable(attemptID: id, choice: .full, until: firstSend.addingTimeInterval(window)))

        await f.clock.advance(by: window - 1)
        let second = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(second, .providerError(status: 502))
        XCTAssertEqual(f.anthropic.resetCalls.map(\.attemptID), [id, id])
        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.full, .full])

        await f.clock.advance(by: 1)
        let late = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(late, .outcome(.unexpected))
        XCTAssertEqual(f.anthropic.resetCount, 2, "past the window nothing is sent")
        XCTAssertEqual(f.anthropic.fetchCount(for: a), 3, "one read after each 5xx and one after the close")
        let after = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(after, "the read made after the close succeeded")
    }

    /// The window is checked again right before the resend that follows a
    /// forced refresh: a refresh that ends past it sends nothing.
    func testARefreshThatCrossesTheWindowSendsNothing() async throws {
        let f = makeFixture(refreshingTokens: true)
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502)), .fail(.needsLogin)], for: a)
        f.anthropic.setRefreshBehavior(.waitThenRotate)
        let id = UUID()

        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        await f.clock.advance(by: window - 10)
        let retry = Task { await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full) }
        await f.anthropic.waitForRefreshCalls(1)
        await f.clock.advance(by: 15)
        f.anthropic.releaseRefreshes()

        let result = await retry.value
        XCTAssertEqual(result, .outcome(.unexpected))
        XCTAssertEqual(f.anthropic.resetCount, 2, "the first send and the rejected retry; no resend")
        XCTAssertEqual(f.anthropic.refreshCount, 1)
    }

    /// When the window ends with no click, the attempt closes with nothing
    /// sent; the one read that follows lifts the hold once it succeeds.
    func testTheWindowEndingClosesTheAttemptWithoutAClick() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502))], for: a)
        let id = UUID()
        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(f.anthropic.fetchCount(for: a), 1)

        let closing = Task { await f.scheduler.closeAttemptWhenWindowEnds(a.id, attemptID: id) }
        _ = await f.clock.parkedSleep(interval: window, number: 1)
        await f.clock.advance(by: window)
        let closed = await closing.value
        XCTAssertEqual(closed, .awaitingReading)
        XCTAssertEqual(f.anthropic.fetchCount(for: a), 1, "closing reads nothing by itself")

        let afterRead = await f.scheduler.readAfterClosedAttempt(a.id)
        XCTAssertNil(afterRead)
        XCTAssertEqual(f.anthropic.fetchCount(for: a), 2)
        XCTAssertEqual(f.anthropic.resetCount, 1)
    }

    // MARK: A refusal after an unanswered send

    /// A refusal of a retry cannot prove the first send spent nothing, so it
    /// is unexpected, and no new attempt is sent until a read made after the
    /// refusal succeeds. The click that finds the hold sends nothing and
    /// asks for that read.
    func testARefusedRetryIsUnexpectedAndHoldsNewAttemptsUntilAFreshRead() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502)), .answer(.nothingToReset), .answer(.reset)], for: a)
        f.anthropic.script([.succeed(usedPercent: 1), .fail(.invalidResponse("test")), .succeed(usedPercent: 2)], for: a)
        let id = UUID()

        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        let refused = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(refused, .outcome(.unexpected))
        let held = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertEqual(held, .awaitingReading, "the read after the refusal failed")

        let blocked = await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full)
        XCTAssertEqual(blocked, .outcome(.needsFreshReading))
        XCTAssertEqual(f.anthropic.resetCount, 2)

        await f.clock.advance(by: BackoffPolicy.errorCap + 1)
        let asksForReading = await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full)
        XCTAssertEqual(asksForReading, .outcome(.needsFreshReading))
        XCTAssertEqual(f.anthropic.resetCount, 2)
        let lifted = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(lifted)

        let fresh = await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full)
        XCTAssertEqual(fresh, .outcome(.reset))
        XCTAssertEqual(f.anthropic.resetCount, 3)
    }

    /// Another kind, or another id, while an attempt is open sends nothing.
    func testAnotherKindWhileAnAttemptIsOpenSendsNothing() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502))], for: a)
        let id = UUID()
        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)

        let otherKind = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .modelRefill)
        let otherID = await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full)
        XCTAssertEqual(otherKind, .alreadyRunning)
        XCTAssertEqual(otherID, .alreadyRunning)
        XCTAssertEqual(f.anthropic.resetCount, 1)
        let state = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertEqual(state, .retryable(attemptID: id, choice: .full, until: f.startTime.addingTimeInterval(window)))
    }

    // MARK: Sign-in

    /// A sign-in forgets the open attempt: a retry of it sends nothing and
    /// ends as not available, and the next click is a new attempt.
    func testASignInRetiresTheOpenAttempt() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.httpStatus(502)), .answer(.reset)], for: a)
        let id = UUID()
        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)

        await f.scheduler.accountDidSignIn(a.id)
        let state = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(state)
        let retry = await f.scheduler.useReset(accountID: a.id, attemptID: id, choice: .full)
        XCTAssertEqual(retry, .outcome(.notAvailable))
        XCTAssertEqual(f.anthropic.resetCount, 1, "the retired attempt sent nothing")

        let fresh = await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full)
        XCTAssertEqual(fresh, .outcome(.reset))
        XCTAssertEqual(f.anthropic.resetCount, 2)
    }

    /// A usage read requested before a sign-in does not publish its numbers
    /// over the new sign-in's row.
    func testAReadRequestedBeforeASignInIsDropped() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.script([.waitThenSucceed(usedPercent: 40)], for: a)

        await f.scheduler.refreshNow()
        await f.anthropic.waitForParkedFetches(1)
        await f.scheduler.accountDidSignIn(a.id)
        f.anthropic.releaseFetches()
        await f.waitForCycles(1)

        let entry = await f.entry(a)
        XCTAssertNil(entry, "the earlier sign-in's reading was not written")
    }

    /// A reset that was running when the account signed in leaves no open
    /// attempt behind for the new sign-in.
    func testAResetAnsweredAfterASignInLeavesNoAttempt() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.hang], for: a)
        let running = Task { await f.scheduler.useReset(accountID: a.id, attemptID: UUID(), choice: .full) }
        await f.anthropic.waitForResetCalls(1)

        await f.scheduler.accountDidSignIn(a.id)
        await f.clock.advance(by: PollScheduler.resetTimeout)
        let result = await running.value
        XCTAssertEqual(result, .unreachable)
        let state = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(state)
    }

    // MARK: Providers without a window

    /// A provider that names no window keeps the old rules: no hold, and a
    /// refusal after an unanswered send is reported as the provider said.
    func testAProviderWithoutAWindowKeepsTheOldRules() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.openai)
        f.openai.scriptResets([.fail(.httpStatus(502)), .answer(.nothingToReset), .answer(.reset)], for: a)
        let id = UUID()

        _ = await f.scheduler.useReset(accountID: a.id, attemptID: id)
        let refused = await f.scheduler.useReset(accountID: a.id, attemptID: id)
        XCTAssertEqual(refused, .outcome(.nothingToReset))
        let next = await f.scheduler.useReset(accountID: a.id, attemptID: UUID())
        XCTAssertEqual(next, .outcome(.reset))
        let state = await f.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(state)
        XCTAssertFalse(f.scheduler.hasResetRetryWindow(.openai))
        XCTAssertTrue(f.scheduler.hasResetRetryWindow(.anthropic))
    }
}
