import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// The reset as the app runs it: a real `AppModel` over the fixture's store,
/// cache, and scheduler, with mock providers. Covers what a person can do
/// while a reset runs (other actions, closing the window, renaming, moving,
/// quitting) and the confirm, cancel, and count-dropped paths.
@MainActor
final class ResetCoordinatorTests: XCTestCase {
    private var harnesses: [ModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.cleanUp()
        }
        harnesses = []
    }

    /// No stagger between reads: a cycle a row action starts mid-test then
    /// runs to its end without the clock, however its reads are ordered or
    /// skipped. Nothing here is about the stagger.
    private func makeHarness(refreshingTokens: Bool = false) -> ModelHarness {
        let fixture = PollingFixture(settings: PollSettings(stagger: 0), refreshingTokens: refreshingTokens)
        let harness = ModelHarness(fixture: fixture)
        harnesses.append(harness)
        return harness
    }

    /// Two Codex accounts holding resets, loaded into a started model with
    /// polling stopped afterwards.
    private func startedHarness(credits: Int = 2) async throws -> (ModelHarness, Account, Account) {
        let h = makeHarness()
        let a = try await h.fixture.addAccount(.openai, email: "a@example.com")
        let b = try await h.fixture.addAccount(.openai, email: "b@example.com")
        h.fixture.openai.setResetCredits(credits)
        await h.start()
        await h.stopPolling()
        return (h, a, b)
    }

    private func task(for account: Account, in model: AppModel) throws -> Task<Void, Never> {
        try XCTUnwrap(model.resetTasks[account.id], "no reset running for \(account.email)")
    }

    // MARK: ISC-219, ISC-220

    func testOtherActionsDoNotCancelTheReset() async throws {
        let (h, a, b) = try await startedHarness()
        let model = h.model
        let mock = h.fixture.openai
        mock.scriptResets([.waitThenAnswer(.reset)], for: a)

        model.useReset(a)
        let running = try task(for: a, in: model)
        await mock.waitForResetCalls(1)

        // Everything else the row and the window offer, mid-run.
        model.refresh(a)
        model.refreshAll()
        model.retryProvider(for: a)
        model.rename(a, to: "Renamed")
        model.moveDown(a)
        model.dismissResetNotice(for: a)
        model.useReset(b)
        await h.fixture.waitForCycles(2)
        await h.waitForModel("rename and move landed") { model in
            model.accounts.first?.id == b.id && model.accounts.last?.nickname == "Renamed"
        }
        XCTAssertTrue(model.resetsInFlight.contains(a.id), "still running after every other action")
        XCTAssertFalse(running.isCancelled)

        mock.releaseResets()
        await running.value
        XCTAssertFalse(running.isCancelled)
        XCTAssertEqual(model.resetNotices[a.id]?.text, ResetMessages.success)
        XCTAssertEqual(mock.resetCalls.filter { $0.accountID == a.id }.count, 1)
        if let other = model.resetTasks[b.id] { await other.value }
    }

    func testResetSurvivesWindowCloseAndReopenShowsTheResult() async throws {
        let (h, a, _) = try await startedHarness()
        let model = h.model
        let mock = h.fixture.openai
        mock.scriptResets([.waitThenAnswer(.reset)], for: a)

        var window: NSWindow? = Self.host(DetailWindow(model: model))
        model.useReset(a)
        let running = try task(for: a, in: model)
        await mock.waitForResetCalls(1)

        // Close the window and let its view state go.
        window?.close()
        window?.contentView = nil
        window = nil
        XCTAssertNil(window)
        try await Task.sleep(for: .milliseconds(100))

        mock.releaseResets()
        await running.value
        XCTAssertFalse(running.isCancelled)
        XCTAssertEqual(model.resetNotices[a.id]?.text, ResetMessages.success)

        // Reopening draws from the model, which holds the result.
        let reopened = Self.host(DetailWindow(model: model))
        defer { reopened.close() }
        XCTAssertEqual(model.resetNotices[a.id]?.kind, .success)
        XCTAssertFalse(model.resetsInFlight.contains(a.id))
    }

    // MARK: ISC-228

    func testSuccessNoteExpiresAndAFailureNoticeStays() async throws {
        let (h, a, b) = try await startedHarness()
        let model = h.model
        h.fixture.openai.scriptResets([.answer(.reset)], for: a)
        h.fixture.openai.scriptResets([.fail(.httpStatus(503))], for: b)

        model.useReset(a)
        model.useReset(b)
        let first = try task(for: a, in: model)
        let second = try task(for: b, in: model)
        await first.value
        await second.value
        XCTAssertEqual(model.resetNotices[a.id]?.kind, .success)
        XCTAssertEqual(model.resetNotices[b.id]?.kind, .failure)

        // The success note's lifetime ends; the failure notice has none.
        h.successNoteFade.open()
        await h.waitForModel("success note faded") { model in model.resetNotices[a.id] == nil }
        XCTAssertEqual(h.successNoteFade.waits, 1, "only the success note asked to fade")
        XCTAssertEqual(model.resetNotices[b.id]?.text, "Codex had a problem (HTTP 503). Try again — a retry never spends a second reset.",
                       "a failure stays until closed")
    }

    // MARK: ISC-307, ISC-349

    /// The confirmation sheet's two buttons, wired exactly as `DetailWindow`
    /// wires them: Cancel only closes the sheet; Use reset calls the model.
    private func confirmation(for account: Account, model: AppModel, closed: @escaping @MainActor () -> Void) -> ResetConfirmation {
        let cached = model.statuses[account.id]
        return ResetConfirmation(
            displayName: account.displayName,
            count: cached?.status.resetCreditsAvailable ?? 0,
            windows: Formatting.popupOrder(Formatting.windows(of: cached)),
            onConfirm: {
                closed()
                model.useReset(account)
            },
            onCancel: { closed() }
        )
    }

    func testConfirmAndCancelPaths() async throws {
        let (h, a, _) = try await startedHarness()
        let model = h.model
        let mock = h.fixture.openai
        var closes = 0

        confirmation(for: a, model: model) { closes += 1 }.onCancel()
        XCTAssertEqual(closes, 1)
        XCTAssertNil(model.resetTasks[a.id], "cancel starts nothing")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.resetCount, 0, "cancel sends nothing")

        confirmation(for: a, model: model) { closes += 1 }.onConfirm()
        try await task(for: a, in: model).value
        XCTAssertEqual(closes, 2)
        XCTAssertEqual(mock.resetCount, 1, "confirm sends exactly one reset")
    }

    func testCountDroppedToZeroAtConfirmSendsNothing() async throws {
        let (h, a, _) = try await startedHarness(credits: 1)
        let model = h.model
        let mock = h.fixture.openai
        let sheet = confirmation(for: a, model: model) {}
        XCTAssertEqual(sheet.count, 1, "the sheet opened with one reset")

        // A poll lands while the sheet is open and reports none left.
        mock.setResetCredits(0)
        model.refreshAll()
        await h.waitForStatus("count dropped to 0") { $0[a.id]?.status.resetCreditsAvailable == 0 }

        sheet.onConfirm()
        XCTAssertNil(model.resetTasks[a.id])
        XCTAssertEqual(model.resetNotices[a.id]?.text, "No resets available")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.resetCount, 0)
    }

    // MARK: ISC-240 (retry reuses the attempt), with fix 1 end to end

    func testRetryAfterAGateway502ReusesTheAttemptID() async throws {
        let (h, a, _) = try await startedHarness()
        let model = h.model
        let mock = h.fixture.openai
        mock.scriptResets([.fail(.httpStatus(502)), .answer(.reset), .answer(.reset)], for: a)

        model.useReset(a)
        try await task(for: a, in: model).value
        model.useReset(a)
        try await task(for: a, in: model).value
        model.useReset(a)
        try await task(for: a, in: model).value

        let ids = mock.resetCalls.map(\.attemptID)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], ids[1], "the click after a 502 retries the same attempt")
        XCTAssertNotEqual(ids[1], ids[2], "the click after a spend is a new attempt")
    }

    // MARK: ISC-342

    func testRenamedAndMovedDuringTheResetLandsOnTheSameAccount() async throws {
        let (h, a, b) = try await startedHarness()
        let model = h.model
        let mock = h.fixture.openai
        mock.scriptResets([.waitThenAnswer(.reset)], for: a)
        mock.setBehavior(.succeed(usedPercent: 0), for: a)

        model.useReset(a)
        let running = try task(for: a, in: model)
        await mock.waitForResetCalls(1)
        model.rename(a, to: "Work")
        model.moveDown(a)
        await h.waitForModel("rename and move landed") { model in
            model.accounts.map(\.id) == [b.id, a.id] && model.accounts.last?.nickname == "Work"
        }

        mock.releaseResets()
        await running.value

        XCTAssertEqual(model.resetNotices[a.id]?.text, ResetMessages.success)
        XCTAssertNil(model.resetNotices[b.id], "the other row gets nothing")
        let entry = try await h.fixture.requireEntry(a)
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 0, "the fresh reading is on the same id")
        XCTAssertEqual(entry.status.accountID, a.id)
        XCTAssertEqual(mock.fetchCount(for: a), 2, "one poll, one read after the reset")
        XCTAssertEqual(mock.fetchCount(for: b), 1)
    }

    // MARK: Hosting

    private static func host<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PopupMetrics.width, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }
}

/// The scheduler side of the reset under failure: a follow-up read that
/// fails or is rate limited, a refresh that is cancelled or fails, and a
/// reset abandoned mid-request (the app quitting).
final class ResetFailurePathTests: XCTestCase {
    private var fixtures: [PollingFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    private func makeFixture(refreshingTokens: Bool = false) -> PollingFixture {
        let fixture = PollingFixture(refreshingTokens: refreshingTokens)
        fixtures.append(fixture)
        return fixture
    }

    private func pollOnceThenStop(_ f: PollingFixture) async {
        await f.pollOnceThenStop()
    }

    // MARK: ISC-263

    func testFreshReadFailsTheResetIsStillUsedAndTheCacheKeepsItsLastReading() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.script([.succeed(usedPercent: 88), .fail(.transport(URLError(.timedOut)))], for: account)
        await pollOnceThenStop(f)
        let before = try await f.requireEntry(account)
        f.openai.scriptResets([.answer(.reset)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .outcome(.reset), "still a success")
        XCTAssertEqual(ResetMessages.notice(for: result, providerName: "Codex", now: f.clock.now())?.text, ResetMessages.success)
        XCTAssertEqual(f.openai.fetchCount(for: account), 2, "one read after the reset, not retried")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after.lastGoodWindows, before.lastGoodWindows, "the last good reading, nothing invented")
        XCTAssertEqual(after.status.windows.first?.usedPercent, 88)
        XCTAssertEqual(after.status.fetchedAt, before.status.fetchedAt, "with its own age")
        XCTAssertTrue(after.isStale)
    }

    // MARK: ISC-297

    func testFollowUpReadRateLimitedArmsTheNormalBackoffAndIsNotLooped() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script([.succeed(usedPercent: 70), .fail(.rateLimited(retryAfter: 1_800))], for: account)
        await pollOnceThenStop(f)
        let before = try await f.requireEntry(account)
        f.anthropic.scriptResets([.answer(.reset)], for: account)
        let readAt = f.clock.now()

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .outcome(.reset), "the reset is still reported used")
        XCTAssertEqual(f.anthropic.fetchCount, 2, "one read, no loop")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after.status.state, .rateLimited(until: readAt.addingTimeInterval(1_800)), "Retry-After honoured")
        XCTAssertEqual(after.lastGoodWindows, before.lastGoodWindows, "last good reading kept")

        // The horizon is the ordinary poll backoff: the next cycle skips.
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the next poll waits out the horizon")
    }

    // MARK: ISC-258

    func testCancellingTheResetMidRefreshStillWritesTheRotatedTokenBack() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.openai)
        let original = try await f.store.credential(for: account.id)?.accessToken
        f.openai.scriptResets([.fail(.needsLogin), .answer(.reset)], for: account)
        f.openai.setRefreshBehavior(.waitThenRotate)

        let running = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await f.openai.waitForRefreshCalls(1)
        running.cancel()
        let result = await running.value
        XCTAssertEqual(result, .unreachable, "the caller gave up")

        f.openai.releaseRefreshes()
        // Joins the refresh still in flight (one per account), so it returns
        // only after the rotated pair has been written back.
        _ = try await f.resolver.validCredential(for: account, from: f.store, using: f.openai)
        let stored = try await f.store.credential(for: account.id)?.accessToken
        XCTAssertEqual(stored, "\(original ?? "")-r1", "the rotated pair is written back")
        XCTAssertEqual(f.openai.refreshCount, 1)
        XCTAssertEqual(f.openai.resetCount, 1, "the resend never went out")
    }

    // MARK: ISC-260

    func testRefreshFailingDuringAResetFlipsNeedsLoginAndKeepsTheRow() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.openai)
        f.openai.setBehavior(.succeed(usedPercent: 30), for: account)
        await pollOnceThenStop(f)
        f.openai.scriptResets([.fail(.needsLogin)], for: account)
        f.openai.setRefreshBehavior(.fail(.needsLogin))

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .needsLogin)
        XCTAssertEqual(f.openai.resetCount, 1, "no resend without a fresh token")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .needsLogin)
        XCTAssertEqual(entry.lastGoodWindows?.first?.usedPercent, 30, "the row keeps its last numbers, dimmed")
        let stored = await f.store.accounts().map(\.id)
        XCTAssertEqual(stored, [account.id], "the row is kept")
        let credential = try await f.store.credential(for: account.id)
        XCTAssertNotNil(credential, "the Keychain item is kept")
    }

    func testAnExpiredTokenWhoseRefreshFailsSendsNoReset() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.openai)
        try await f.store.updateCredential(
            AccountCredential(accessToken: "expired", refreshToken: "refresh", expiresAt: f.clock.now()),
            for: account.id
        )
        f.openai.setRefreshBehavior(.fail(.needsLogin))

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .needsLogin)
        XCTAssertEqual(f.openai.resetCount, 0)
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .needsLogin)
        let stored = await f.store.accounts().map(\.id)
        XCTAssertEqual(stored, [account.id])
    }

    // MARK: ISC-347

    func testQuittingAfterTheResetWasSentLeavesTheFilesValid() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        let paths = AppPaths(applicationSupportDirectory: f.directory)
        let persistence = StatusCachePersistence(paths: paths, clock: f.clock, minimumWriteInterval: 0)
        await pollOnceThenStop(f)
        // Started after the poll, so every snapshot it can write holds the
        // account, whenever its observer gets to it.
        await persistence.observe(f.cache)
        f.openai.scriptResets([.waitThenAnswer(.reset)], for: account)

        let running = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await f.openai.waitForResetCalls(1)
        running.cancel()
        let result = await running.value
        XCTAssertEqual(result, .unreachable)
        // Quitting writes the cache's newest state, whether or not the
        // observer has delivered it yet.
        await persistence.record(await f.cache.snapshot())
        await persistence.flush()
        await persistence.stop()
        f.openai.releaseResets()

        let data = try Data(contentsOf: paths.statusCacheFile)
        let decoded = try StatusCachePersistence.decode(data)
        XCTAssertEqual(decoded[account.id]?.status.accountID, account.id, "the status cache decodes")
        let relaunched = f.relaunched()
        let accounts = try await relaunched.store.load()
        XCTAssertEqual(accounts.map(\.id), [account.id], "accounts.json decodes")
        let credential = try await relaunched.store.credential(for: account.id)
        XCTAssertNotNil(credential, "the Keychain item is intact")
    }
}
