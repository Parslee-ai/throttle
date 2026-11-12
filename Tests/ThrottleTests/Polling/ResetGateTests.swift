import XCTest
@testable import Throttle

/// `AppModel.resetGates` for a provider with a retry window: retry-only while
/// an unanswered attempt may still be retried, awaiting-reading from its
/// close until the next successful reading, flipped at the window's end with
/// no click, and cleared by a sign-in or a removal.
@MainActor
final class ResetGateTests: XCTestCase {
    private var harnesses: [ModelHarness] = []
    private let window: TimeInterval = 600

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.cleanUp()
        }
        harnesses = []
    }

    /// One Claude account with a full reset and a model refill, a 10-minute
    /// retry window, and polling stopped after the first cycle.
    private func gatedHarness() async throws -> (ModelHarness, Account) {
        let fixture = PollingFixture(settings: PollSettings(stagger: 0))
        let h = ModelHarness(fixture: fixture)
        harnesses.append(h)
        let account = try await fixture.addAccount(.anthropic, email: "fixture-gates")
        fixture.anthropic.setResetRetryWindow(window)
        fixture.anthropic.setResetKinds([
            ResetKind(key: .full, label: "Full reset", count: 2),
            ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1),
        ])
        await h.start()
        await h.stopPolling()
        return (h, account)
    }

    private func finish(_ account: Account, in model: AppModel) async throws {
        try await XCTUnwrap(model.resetTasks[account.id], "no reset running").value
    }

    func testAnUnansweredAttemptOffersOnlyItsRetry() async throws {
        let (h, a) = try await gatedHarness()
        let mock = h.fixture.anthropic
        mock.scriptResets([.fail(.httpStatus(502)), .answer(.reset)], for: a)

        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        XCTAssertEqual(h.model.resetGates[a.id], .retryOnly(kind: .full, label: "Full reset"))

        h.model.useReset(a, choice: .modelRefill)
        h.model.useReset(a, choice: .full)
        XCTAssertNil(h.model.resetTasks[a.id], "a new attempt sends nothing while the gate is up")
        h.model.useReset(a, choice: .modelRefill, retrying: true)
        XCTAssertNil(h.model.resetTasks[a.id], "a retry is only of the attempt's own kind")

        h.model.useReset(a, choice: .full, retrying: true)
        try await finish(a, in: h.model)
        XCTAssertEqual(mock.resetCalls.map(\.choice), [.full, .full])
        XCTAssertEqual(mock.resetCalls[0].attemptID, mock.resetCalls[1].attemptID)
        XCTAssertNil(h.model.resetGates[a.id], "a definite answer lifts the gate")
    }

    /// A retry skips the count check: the reading may show the kind spent by
    /// the very send being retried.
    func testARetryIsSentEvenWhenTheReadingShowsTheKindAtZero() async throws {
        let (h, a) = try await gatedHarness()
        let mock = h.fixture.anthropic
        mock.scriptResets([.fail(.httpStatus(502)), .answer(.reset)], for: a)
        mock.setResetKinds([ResetKind(key: .full, label: "Full reset", count: 0)])

        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        await h.waitForStatus("the read after the 5xx shows zero") { $0[a.id]?.status.resetCreditsAvailable == 0 }
        h.model.useReset(a, choice: .full, retrying: true)
        try await finish(a, in: h.model)
        XCTAssertEqual(mock.resetCount, 2)
    }

    /// At the window's end the gate flips with no click, and a retry
    /// confirmed after that sends nothing and starts nothing. The next
    /// successful reading lifts the gate.
    func testTheGateFlipsAtTheWindowsEndAndLiftsOnTheNextReading() async throws {
        let (h, a) = try await gatedHarness()
        let mock = h.fixture.anthropic
        mock.scriptResets([.fail(.httpStatus(502))], for: a)
        // The read after the 5xx succeeds, then the read after the close
        // fails, so the gate holds until a later one succeeds.
        mock.script([.succeed(usedPercent: 1), .fail(.invalidResponse("test")), .succeed(usedPercent: 3)], for: a)

        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        _ = await h.fixture.clock.parkedSleep(interval: window, number: 1)
        await h.fixture.clock.advance(by: window)
        await h.waitForModel("the gate flipped") { $0.resetGates[a.id] == .awaitingReading }
        await waitUntil("the read after the close ran") { mock.fetchCount(for: a) == 3 }
        await h.fixture.clock.settle()
        XCTAssertEqual(h.model.resetGates[a.id], .awaitingReading)

        h.model.useReset(a, choice: .full, retrying: true)
        h.model.useReset(a, choice: .full)
        XCTAssertNil(h.model.resetTasks[a.id])
        XCTAssertEqual(mock.resetCount, 1)

        await h.fixture.clock.advance(by: BackoffPolicy.errorCap + 1)
        h.model.refreshAll()
        await h.waitForModel("a fresh reading lifted the gate") { $0.resetGates[a.id] == nil }
    }

    func testASignInClearsTheGate() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(502)), .answer(.reset)], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        XCTAssertNotNil(h.model.resetGates[a.id])

        await h.model.accountDidSignIn(a.id, provider: .anthropic)
        XCTAssertNil(h.model.resetGates[a.id])
        XCTAssertNil(h.model.retryWindowTasks[a.id])
        let state = await h.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(state)

        h.model.useReset(a, choice: .full, retrying: true)
        XCTAssertNil(h.model.resetTasks[a.id], "the old attempt is gone, so a retry sends nothing")
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        XCTAssertNotEqual(h.fixture.anthropic.resetCalls[0].attemptID, h.fixture.anthropic.resetCalls[1].attemptID)
    }

    func testRemovingTheRowClearsTheGate() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(502))], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)

        h.model.remove(a)
        XCTAssertNil(h.model.resetGates[a.id])
        XCTAssertNil(h.model.retryWindowTasks[a.id])
        await waitUntil("the scheduler forgot the attempt") {
            await h.scheduler.resetAttemptState(for: a.id) == nil
        }
    }

    /// A provider with no window never gets a gate.
    func testAProviderWithoutAWindowGetsNoGate() async throws {
        let fixture = PollingFixture(settings: PollSettings(stagger: 0))
        let h = ModelHarness(fixture: fixture)
        harnesses.append(h)
        let a = try await fixture.addAccount(.openai, email: "fixture-nogate")
        fixture.openai.setResetCredits(2)
        fixture.openai.scriptResets([.fail(.httpStatus(502))], for: a)
        await h.start()
        await h.stopPolling()

        h.model.useReset(a)
        try await finish(a, in: h.model)
        XCTAssertNil(h.model.resetGates[a.id])
    }
}
