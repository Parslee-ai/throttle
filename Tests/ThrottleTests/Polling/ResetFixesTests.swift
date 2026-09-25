import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// Regression tests for five defects an independent verifier found in the
/// reset path. Each one failed on the code before its fix.
final class ResetFixesTests: XCTestCase {
    private var fixtures: [PollingFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    private func makeFixture() -> PollingFixture {
        let fixture = PollingFixture()
        fixtures.append(fixture)
        return fixture
    }

    private func pollOnceThenStop(_ f: PollingFixture) async {
        await f.pollOnceThenStop()
    }

    // MARK: 1. No double spend after an ambiguous answer

    /// A 5xx can come from a gateway after the provider already spent the
    /// reset, and an unreadable 200 may be a spend too. The next click must
    /// resend the same attempt id so the provider treats it as a repeat.
    func testAmbiguousResultsKeepTheAttemptID() {
        let ambiguous: [ResetResult] = [
            .unreachable,
            .providerError(status: 500),
            .providerError(status: 502),
            .providerError(status: 503),
            .providerError(status: 504),
            .outcome(.unexpected),
            .unexpected,
        ]
        for result in ambiguous {
            var attempts = ResetAttempts()
            let account = UUID()
            let first = attempts.attemptID(for: account)
            attempts.finish(account, with: result)
            XCTAssertEqual(attempts.attemptID(for: account), first, "\(result) must keep the attempt")
        }
    }

    func testDefinitiveAnswersAndClientRefusalsEndTheAttempt() {
        let ending: [ResetResult] = [
            .outcome(.reset),
            .outcome(.nothingToReset),
            .outcome(.noCredit),
            .outcome(.cooldown(until: nil)),
            .outcome(.notAvailable),
            .needsLogin,
            .forbidden(reason: "no"),
            .rateLimited(until: nil),
            .providerError(status: 302),
            .providerError(status: 400),
            .providerError(status: 404),
            .providerError(status: 409),
        ]
        for result in ending {
            var attempts = ResetAttempts()
            let account = UUID()
            let first = attempts.attemptID(for: account)
            attempts.finish(account, with: result)
            XCTAssertNotEqual(attempts.attemptID(for: account), first, "\(result) ends the attempt")
        }
    }

    /// After an ambiguous send, a refusal of the retry says nothing about the
    /// first send, so the id is still kept; a definitive answer then ends it.
    func testAfterAnAmbiguousSendOnlyADefinitiveAnswerEndsTheAttempt() {
        var attempts = ResetAttempts()
        let account = UUID()
        let first = attempts.attemptID(for: account)
        attempts.finish(account, with: .providerError(status: 502))
        attempts.finish(account, with: .rateLimited(until: nil))
        XCTAssertEqual(attempts.attemptID(for: account), first)
        attempts.finish(account, with: .needsLogin)
        XCTAssertEqual(attempts.attemptID(for: account), first)
        attempts.finish(account, with: .alreadyRunning)
        XCTAssertEqual(attempts.attemptID(for: account), first)
        attempts.finish(account, with: .outcome(.reset))
        XCTAssertNotEqual(attempts.attemptID(for: account), first)
    }

    // MARK: 2. No reset while backed off

    func testProviderUnderBackoffSendsNoReset() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setResetCredits(1)
        f.anthropic.script([.succeed(usedPercent: 50), .fail(.rateLimited(retryAfter: 1_800))], for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        await f.scheduler.stop()
        let horizon = f.clock.now().addingTimeInterval(1_800)
        let before = try await f.requireEntry(account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .rateLimited(until: horizon))
        XCTAssertEqual(f.anthropic.resetCount, 0, "nothing is sent inside the horizon")
        XCTAssertEqual(f.anthropic.fetchCount, 2, "and nothing is read")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after, before)
        let notice = ResetMessages.notice(for: result, providerName: "Claude", now: f.clock.now())
        XCTAssertEqual(notice?.text, "Claude is limiting requests — try again at \(Formatting.clockTime(horizon))")
    }

    /// A sibling's 429 arms the provider-wide Claude horizon; this account's
    /// reset is held too.
    func testSiblingRateLimitHoldsTheReset() async throws {
        let f = makeFixture()
        let target = try await f.addAccount(.anthropic)
        let sibling = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.fail(.rateLimited(retryAfter: 600)), for: sibling)
        await pollOnceThenStop(f)

        let result = await f.scheduler.useReset(accountID: target.id, attemptID: UUID())

        guard case .rateLimited(let until?) = result else {
            return XCTFail("expected a rate-limit refusal, got \(result)")
        }
        XCTAssertGreaterThan(until, f.clock.now())
        XCTAssertEqual(f.anthropic.resetCount, 0)
    }

    func testForbiddenHoldSendsNoReset() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.setBehavior(.fail(.forbidden(reason: "not allowed")), for: account)
        let heldAt = f.clock.now()
        await pollOnceThenStop(f)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .rateLimited(until: heldAt.addingTimeInterval(BackoffPolicy.forbiddenHold)))
        XCTAssertEqual(f.openai.resetCount, 0)
    }

    // MARK: 3. A removal during the read never resurrects the entry

    /// The removal lands in the gap between the scheduler's "still stored?"
    /// check and its cache write: here the cache has already dropped the
    /// account (as `AppModel.remove` makes it do) while the store still lists
    /// it, which is exactly what the scheduler sees in that gap.
    func testRemovalDuringTheFollowUpReadDoesNotResurrectTheEntry() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        await pollOnceThenStop(f)
        let cache = f.cache
        f.openai.onFetch { id, number in
            // The follow-up read is this account's second fetch.
            if id == account.id, number == 2 {
                await cache.retain(accountIDs: [])
            }
        }
        f.openai.scriptResets([.answer(.reset)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        try await f.store.remove(id: account.id)

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "the read ran")
        let entry = await f.entry(account)
        XCTAssertNil(entry, "a removed row never gets its entry back")
    }

    // MARK: 4. Never two concurrent reads for one account

    /// A slow poll read is in flight when the reset lands. The read after the
    /// reset waits for it; since that poll started before the reset
    /// finished, its numbers may predate the reset, so one more read follows,
    /// after it, never beside it.
    func testFollowUpReadWaitsForAPollReadInFlight() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.script([.succeed(usedPercent: 90), .waitThenSucceed(usedPercent: 90), .succeed(usedPercent: 0)], for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.refreshNow()
        await f.openai.waitForParkedFetches(1)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await f.openai.waitForResetCalls(1)
        await f.clock.settle()
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "no second read while the poll's is running")

        f.openai.releaseFetches()
        let result = await reset.value
        await f.waitForCycles(2)

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.openai.maxConcurrentFetches(for: account), 1, "never two reads at once")
        XCTAssertEqual(f.openai.fetchCount(for: account), 3, "the post-reset read ran after the poll's")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 0, "the row ends on the post-reset reading")
    }

    /// The other order: the read after the reset is slow and a poll arrives.
    /// The poll waits, then takes the fresh reading as its own and sends
    /// nothing.
    func testPollWaitsForTheFollowUpReadAndSkips() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.script([.succeed(usedPercent: 90), .waitThenSucceed(usedPercent: 0), .succeed(usedPercent: 55)], for: account)
        await pollOnceThenStop(f)
        f.openai.scriptResets([.answer(.reset)], for: account)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await f.openai.waitForParkedFetches(1)
        await f.scheduler.refreshNow()
        await f.clock.settle()
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "the poll does not read beside the follow-up")

        f.openai.releaseFetches()
        _ = await reset.value
        await f.waitForCycles(2)

        XCTAssertEqual(f.openai.maxConcurrentFetches(for: account), 1)
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "the poll used the fresh reading")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 0)
    }
}

// MARK: 5. Reset messages fit the row

/// Every group-A message renders in full, never cut, in each place the
/// resets column can sit: first on its line (a Claude row: three windows,
/// the count alone on a second line), second (a Codex row: one window, then
/// the count), and third (a row with two windows, then the count). A message
/// that fits on one line from the column to the end of its line of columns
/// is drawn there and costs the row no height; one that does not is drawn on
/// a line of its own under the columns, the full width of a line.
@MainActor
final class ResetNoticeFitTests: XCTestCase {
    private let now = UIFixtures.now

    private func fittedHeight<V: View>(_ view: V, width: CGFloat = PopupMetrics.width) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func row(provider: Provider, windows: [UsageWindow], notice: ResetNotice?) -> some View {
        let account = UIFixtures.account("fit@example.com", provider: provider)
        return AccountRow(
            account: account,
            number: 1,
            cached: UIFixtures.cached(for: account, windows: windows, planLabel: "pro", resetCreditsAvailable: 1),
            planLabel: "pro",
            now: now,
            isFirstInSection: true,
            isLastInSection: true,
            resetNotice: notice
        )
    }

    private func groupAMessages(provider: String) -> [String] {
        let results: [ResetResult] = [
            .outcome(.reset),
            .outcome(.nothingToReset),
            .outcome(.noCredit),
            .outcome(.cooldown(until: now.addingTimeInterval(3_600))),
            .outcome(.cooldown(until: now.addingTimeInterval(3 * 86_400))),
            .outcome(.notAvailable),
            .outcome(.unexpected),
            .rateLimited(until: now.addingTimeInterval(3_600)),
            .rateLimited(until: now.addingTimeInterval(3 * 86_400)),
            .rateLimited(until: nil),
            .providerError(status: 503),
            .providerError(status: 404),
            .unreachable,
            .forbidden(reason: ""),
        ]
        return results.compactMap { ResetMessages.notice(for: $0, providerName: provider, now: now)?.text }
    }

    /// Lines `message` takes, with no limit, in the notice's font at the
    /// width a notice across `span` gives its text.
    private func naturalLines(_ message: String, span: CGFloat) -> Int {
        let width = ResetCreditsColumn.noticeTextWidth(span: span)
        func height(_ text: String) -> CGFloat {
            fittedHeight(
                Text(text).font(.system(size: ResetCreditsColumn.noticeFontSize)).fixedSize(horizontal: false, vertical: true),
                width: width
            )
        }
        return Int((height(message) / height("A")).rounded())
    }

    private struct Placement {
        let below: Bool
        let lines: Int
    }

    /// Where the row draws `message` for a resets column in `slot`, and how
    /// many lines it takes there.
    private func placement(_ message: String, slot: Int) -> Placement {
        let below = AccountRow.noticeGoesBelowColumns(message, resetsSlot: slot)
        let span = below ? PopupMetrics.columnsLineWidth : PopupMetrics.lineRemainder(fromSlot: slot)
        return Placement(below: below, lines: naturalLines(message, span: span))
    }

    /// The row's height with one line of message under its columns.
    private func heightWithOneLineBelow(provider: Provider, windows: [UsageWindow]) -> CGFloat {
        let wide = "A message only as wide as a line of columns: " + String(repeating: "wide ", count: 30)
        var text = wide
        while ResetCreditsColumn.noticeFitsOnOneLine(text, span: PopupMetrics.columnsLineWidth) == false {
            text.removeLast()
        }
        XCTAssertTrue(AccountRow.noticeGoesBelowColumns(text, resetsSlot: 1))
        return fittedHeight(row(provider: provider, windows: windows, notice: ResetNotice(text, kind: .failure)))
    }

    func testEveryGroupAMessageIsOneUncutLineInTheFirstAndSecondPositions() {
        let shapes: [(String, Provider, [UsageWindow], Int)] = [
            ("Codex", .openai, [UIFixtures.window("7d", label: "Weekly", used: 40)], 1),
            ("Claude", .anthropic, [
                UIFixtures.window("5h", label: "5h", used: 10),
                UIFixtures.window("7d", label: "Weekly", used: 20),
                UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 30),
            ], 0),
        ]
        for (name, provider, windows, slot) in shapes {
            let oneLine = fittedHeight(row(provider: provider, windows: windows, notice: ResetNotice("OK", kind: .failure)))
            let below = heightWithOneLineBelow(provider: provider, windows: windows)
            if slot == 1 {
                // Beside a window column the in-place line is free; a line
                // under the columns is not.
                XCTAssertGreaterThan(below, oneLine)
            }
            let messages = groupAMessages(provider: name)
            XCTAssertEqual(messages.count, 14)
            XCTAssertTrue(messages.contains("\(name) had a problem (HTTP 503). Try again — a retry never spends a second reset."))
            XCTAssertTrue(messages.contains("\(name) couldn't use the reset (HTTP 404). Nothing was changed."))
            for message in messages {
                let place = placement(message, slot: slot)
                XCTAssertEqual(place.lines, 1, "\(name) row: \"\(message)\" wraps")
                let height = fittedHeight(row(provider: provider, windows: windows, notice: ResetNotice(message, kind: .failure)))
                XCTAssertEqual(height, place.below ? below : oneLine, "\(name) row: \"\(message)\" wraps or is cut")
            }
            if slot == 0 {
                XCTAssertFalse(messages.contains { placement($0, slot: 0).below }, "a first-position column holds every message")
            }
        }
    }

    /// Two windows put the count third on its line (a Codex row with a
    /// 5-hour and a weekly window). The column has only its own width there,
    /// so a long message moves under the columns. No message takes more than
    /// two lines, none is cut, and the row grows by one line at most.
    func testEveryGroupAMessageFitsInTwoLinesInTheThirdPosition() {
        let windows = [
            UIFixtures.window("5h", label: "5h", used: 10, seconds: 18_000),
            UIFixtures.window("7d", label: "Weekly", used: 20),
        ]
        for name in ["Codex", "Claude"] {
            let provider: Provider = name == "Codex" ? .openai : .anthropic
            let oneLine = fittedHeight(row(provider: provider, windows: windows, notice: ResetNotice("OK", kind: .failure)))
            let below = heightWithOneLineBelow(provider: provider, windows: windows)
            let messages = groupAMessages(provider: name)
            XCTAssertEqual(messages.count, 14)
            var moved = 0
            for message in messages {
                let place = placement(message, slot: 2)
                XCTAssertGreaterThanOrEqual(place.lines, 1)
                XCTAssertLessThanOrEqual(place.lines, ResetCreditsColumn.noticeLineLimit,
                                         "\(name) third position: \"\(message)\" needs \(place.lines) lines, so it would be cut")
                if place.below { moved += 1 }
                let height = fittedHeight(row(provider: provider, windows: windows, notice: ResetNotice(message, kind: .failure)))
                XCTAssertLessThanOrEqual(height, below, "\(name) third position: \"\(message)\" adds more than one line")
                XCTAssertEqual(height, place.below ? below : oneLine, "\(name) third position: \"\(message)\"")
            }
            XCTAssertGreaterThan(moved, 0, "the third position is narrow enough that long messages move under the columns")
        }
    }
}
