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

    // MARK: No message promises a retry that is no longer there

    private func offer(_ h: ModelHarness, _ a: Account) -> ResetOffer {
        let status = h.model.statuses[a.id]?.status
        return ResetOffer(count: status?.resetCreditsAvailable ?? 0, kinds: status?.resetKinds,
                          dimmed: false, gate: h.model.resetGates[a.id], now: h.fixture.clock.now())
    }

    /// When the window ends with no click, the row stops promising a free
    /// retry at that moment: it reads "Unexpected answer", offers nothing
    /// until a fresh reading, and still makes no promise once that reading
    /// makes the next click a new attempt. Holds for a 5xx and for no answer.
    func testTheWindowEndingReplacesTheRetryMessage() async throws {
        // A 5xx is followed by a read; no answer is not. The read after the
        // close fails either way, so the hold stays until a later one.
        let cases: [(UsageError, [MockUsageProvider.Behavior], Int)] = [
            (.httpStatus(503), [.succeed(usedPercent: 1), .fail(.invalidResponse("test")), .succeed(usedPercent: 3)], 3),
            (.transport(URLError(.timedOut)), [.fail(.invalidResponse("test")), .succeed(usedPercent: 3)], 2),
        ]
        for (failure, reads, readsAfterClose) in cases {
            let (h, a) = try await gatedHarness()
            let mock = h.fixture.anthropic
            mock.scriptResets([.fail(failure)], for: a)
            mock.script(reads, for: a)

            h.model.useReset(a, choice: .full)
            try await finish(a, in: h.model)
            let promise = try XCTUnwrap(h.model.resetNotices[a.id]?.text)
            XCTAssertTrue(promise.lowercased().contains("try again"), "\(failure): \(promise)")

            _ = await h.fixture.clock.parkedSleep(interval: window, number: 1)
            await h.fixture.clock.advance(by: window)
            await h.waitForModel("the gate flipped") { $0.resetGates[a.id] == .awaitingReading }
            XCTAssertEqual(h.model.resetNotices[a.id]?.text, "Unexpected answer from Claude", "\(failure)")
            XCTAssertEqual(offer(h, a).disabledReason, ResetMessages.waitingForFreshReading)
            await waitUntil("the read after the close ran") { mock.fetchCount(for: a) == readsAfterClose }
            await h.fixture.clock.settle()
            XCTAssertEqual(h.model.resetNotices[a.id]?.text, "Unexpected answer from Claude")

            await h.fixture.clock.advance(by: BackoffPolicy.errorCap + 1)
            h.model.refreshAll()
            await h.waitForModel("a fresh reading lifted the gate") { $0.resetGates[a.id] == nil }
            XCTAssertNil(offer(h, a).disabledReason, "the next click is a new attempt")
            XCTAssertEqual(h.model.resetNotices[a.id]?.text, "Unexpected answer from Claude",
                           "\(failure): no promise of a free retry beside a new attempt")
        }
    }

    /// A refused retry ends the attempt with the same words.
    func testARefusedRetrySaysUnexpected() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(503)), .answer(.nothingToReset)], for: a)
        // The read after the refusal fails, so the hold stays.
        h.fixture.anthropic.script([.succeed(usedPercent: 1), .fail(.invalidResponse("test"))], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        h.model.useReset(a, choice: .full, retrying: true)
        try await finish(a, in: h.model)
        XCTAssertEqual(h.model.resetGates[a.id], .awaitingReading)
        XCTAssertEqual(h.model.resetNotices[a.id]?.text, "Unexpected answer from Claude")
    }

    /// A sign-in ends the attempt, so a message promising its retry goes,
    /// with a retry window or without one.
    func testASignInDropsAMessagePromisingARetry() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(503))], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        XCTAssertNotNil(h.model.resetNotices[a.id])
        await h.model.accountDidSignIn(a.id, provider: .anthropic)
        XCTAssertNil(h.model.resetNotices[a.id])

        let fixture = PollingFixture(settings: PollSettings(stagger: 0))
        let codex = ModelHarness(fixture: fixture)
        harnesses.append(codex)
        let c = try await fixture.addAccount(.openai, email: "fixture-codex")
        fixture.openai.setResetCredits(2)
        fixture.openai.scriptResets([.fail(.httpStatus(502))], for: c)
        await codex.start()
        await codex.stopPolling()
        codex.model.useReset(c)
        try await finish(c, in: codex.model)
        XCTAssertNotNil(codex.model.resetNotices[c.id])
        await codex.model.accountDidSignIn(c.id, provider: .openai)
        XCTAssertNil(codex.model.resetNotices[c.id])
    }

    /// A message that promises nothing outlives a sign-in.
    func testASignInKeepsAMessageThatPromisesNoRetry() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(404))], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        let text = h.model.resetNotices[a.id]?.text
        XCTAssertEqual(text, "Claude couldn't use the reset (HTTP 404). Nothing was changed.")
        await h.model.accountDidSignIn(a.id, provider: .anthropic)
        XCTAssertEqual(h.model.resetNotices[a.id]?.text, text)
    }

    /// Removing the row takes its message with it.
    func testRemovingTheRowDropsItsMessage() async throws {
        let (h, a) = try await gatedHarness()
        h.fixture.anthropic.scriptResets([.fail(.httpStatus(503))], for: a)
        h.model.useReset(a, choice: .full)
        try await finish(a, in: h.model)
        h.model.remove(a)
        XCTAssertNil(h.model.resetNotices[a.id])
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
