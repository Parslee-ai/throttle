import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// The real reset confirmation, hosted in a window and wired to the real
/// `AppModel` exactly as `DetailWindow` wires it, over the real scheduler and
/// Claude adapter and the scripted HTTP client. Clicks and keys go to the
/// window as events, so what reaches the wire is what a person's pick and
/// press would send.
///
/// The tests that use it are synchronous and spin the main run loop while
/// they wait, so SwiftUI can lay out and handle events between steps.
@MainActor
struct HostedResetFlow {
    let kinds: ClaudeKindsFixture
    let harness: ModelHarness
    let account: Account

    var model: AppModel { harness.model }

    /// One Claude account read once from the kinds fixture (usage, then the
    /// profile), with polling stopped afterwards.
    static func started(email: String = "fixture-flow") throws -> HostedResetFlow {
        let kinds = ClaudeKindsFixture()
        let harness = ModelHarness(fixture: kinds.fixture, scheduler: kinds.scheduler)
        let account = try wait("the first reading") {
            let account = try await kinds.fixture.addAccount(.anthropic, email: email)
            try kinds.enqueueReading()
            kinds.enqueueProfile()
            await harness.start()
            await harness.stopPolling()
            return account
        }
        return HostedResetFlow(kinds: kinds, harness: harness, account: account)
    }

    func cleanUp() async {
        await harness.cleanUp()
    }

    /// The card as `DetailWindow` builds it for this account now, with the
    /// gate it opens under; confirming calls the model, cancelling counts.
    func card(onCancel: @escaping @MainActor () -> Void = {}) -> ResetConfirmation {
        let cached = model.statuses[account.id]
        let model = model
        let account = account
        return ResetConfirmation(
            displayName: account.displayName,
            count: cached?.status.resetCreditsAvailable ?? 0,
            windows: Formatting.windowOrder(Formatting.windows(of: cached)),
            kinds: cached?.status.resetKinds,
            gate: model.resetGates[account.id],
            onChoice: { model.confirmReset(account, choice: $0) },
            onCancel: onCancel
        )
    }

    /// Waits out a reset that may still be running. The stub answers at
    /// once, so a reset started by a click can end inside the click's own
    /// run-loop turn; what was sent is asserted from the recorded requests.
    func finishReset() throws {
        if let task = model.resetTasks[account.id] {
            try Self.wait("the reset") { await task.value }
        }
        XCTAssertFalse(model.resetsInFlight.contains(account.id), "the reset is still running")
    }

    // MARK: Waiting

    /// Runs `body` on the main actor and spins the main run loop until it
    /// returns. Fails after `timeout`, which only happens when something is
    /// stuck.
    @discardableResult
    static func wait<T>(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        Task { @MainActor in
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while box.result == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard let result = box.result else {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            throw CancellationError()
        }
        return try result.get()
    }

    @MainActor
    private final class ResultBox<T> {
        var result: Result<T, any Error>?
    }

    // MARK: Hosting

    /// Shows `view` in a key window off screen: it needs to be key, not seen.
    static func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        settle()
        return window
    }

    /// Lets SwiftUI apply a state change and redraw.
    static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    /// Clicks at `point`, in window coordinates.
    static func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        settle()
    }

    /// Where a hosted card's controls are, worked out from its layout
    /// (`ConfirmationCard`: 20 pt padding, title, 12 pt gap, then the kind
    /// list's 24 pt lines 2 pt apart inside 4 pt of padding; Cancel at the
    /// trailing edge of the bottom row and the confirm button 8 pt before
    /// it). SwiftUI keeps no accessibility tree until an assistive app asks
    /// for one, so a click at the right place is how a test presses.
    @MainActor
    struct CardLayout {
        let window: NSWindow
        let title: String

        private var height: CGFloat { window.contentView?.frame.height ?? 0 }
        private static let padding: CGFloat = 20
        private static let width: CGFloat = 380
        private static let buttonRowMid: CGFloat = 32

        private static func fitting<V: View>(_ view: V) -> CGSize {
            NSHostingView(rootView: view).fittingSize
        }

        private var cancelWidth: CGFloat { Self.fitting(Button("Cancel") {}).width }

        /// The middle of the `index`th kind line in the list.
        func kindLine(_ index: Int) -> NSPoint {
            let titleHeight = Self.fitting(
                Text(title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width - 2 * Self.padding, alignment: .leading)
            ).height
            let fromTop = Self.padding + titleHeight + 12 + 4 + 12 + CGFloat(index) * 26
            return NSPoint(x: Self.width / 2, y: height - fromTop)
        }

        /// Just inside the confirm button's trailing edge.
        var confirm: NSPoint {
            NSPoint(x: Self.width - Self.padding - cancelWidth - 8 - 12, y: Self.buttonRowMid)
        }

        var cancel: NSPoint {
            NSPoint(x: Self.width - Self.padding - cancelWidth / 2, y: Self.buttonRowMid)
        }
    }

    /// Sends Return or Escape to the window.
    static func key(_ code: UInt16, to window: NSWindow) throws {
        let characters = code == returnKey ? "\r" : "\u{1b}"
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        settle()
    }

    static let returnKey: UInt16 = 36
    static let escapeKey: UInt16 = 53
}

// MARK: - The pick reaches the wire (ISC-522, ISC-523)

extension ResetUITests {
    /// Picking the second of two kinds and confirming sends one POST, and it
    /// carries that kind's grant.
    func testPickReachesWire() throws {
        let flow = try HostedResetFlow.started()
        addTeardownBlock { await flow.cleanUp() }
        XCTAssertEqual(flow.model.statuses[flow.account.id]?.status.resetKinds?.map(\.key), [.full, .modelRefill])
        flow.kinds.enqueueResetAnswer()
        try flow.kinds.enqueueReading()

        let window = HostedResetFlow.host(flow.card())
        defer { window.close() }
        let card = flow.pickLayout(in: window)
        try HostedResetFlow.click(card.kindLine(1), in: window)
        try HostedResetFlow.click(card.confirm, in: window)
        try flow.finishReset()

        XCTAssertEqual(try flow.kinds.grantIDs(), [ClaudeKindsFixture.refillGrant], "one POST, for the kind picked")
        XCTAssertEqual(flow.model.resetNotices[flow.account.id]?.text, "Testmodel reset used — limits refreshed")
    }

    /// Opening the card, picking, changing the pick, Return and Escape before
    /// and after a pick, and Cancel send nothing of any kind. The card's own
    /// confirm button, pressed at the end, then sends the last pick: so every
    /// step before it acted on a real pick and still sent nothing.
    func testConfirmSendsNothingUntilConfirmed() throws {
        let flow = try HostedResetFlow.started()
        addTeardownBlock { await flow.cleanUp() }
        let before = flow.kinds.http.requests.count
        var cancels = 0
        func assertNothingSent(_ step: String, line: UInt = #line) {
            HostedResetFlow.settle()
            XCTAssertEqual(flow.kinds.http.requests.count, before, "\(step): a request went out", line: line)
            XCTAssertNil(flow.model.resetTasks[flow.account.id], "\(step): a reset started", line: line)
        }

        let window = HostedResetFlow.host(flow.card { cancels += 1 })
        defer { window.close() }
        let card = flow.pickLayout(in: window)
        assertNothingSent("open")
        try HostedResetFlow.click(card.confirm, in: window)
        assertNothingSent("Use reset before a pick")
        try HostedResetFlow.key(HostedResetFlow.returnKey, to: window)
        assertNothingSent("Return before a pick")
        try HostedResetFlow.key(HostedResetFlow.escapeKey, to: window)
        assertNothingSent("Escape before a pick")
        try HostedResetFlow.click(card.kindLine(0), in: window)
        assertNothingSent("pick")
        try HostedResetFlow.click(card.kindLine(1), in: window)
        assertNothingSent("change the pick")
        try HostedResetFlow.key(HostedResetFlow.returnKey, to: window)
        assertNothingSent("Return after a pick")
        try HostedResetFlow.key(HostedResetFlow.escapeKey, to: window)
        assertNothingSent("Escape after a pick")
        try HostedResetFlow.click(card.cancel, in: window)
        assertNothingSent("Cancel")
        XCTAssertEqual(cancels, 5, "Return and Escape, twice each, and Cancel each closed the card")

        flow.kinds.enqueueResetAnswer()
        try flow.kinds.enqueueReading()
        try HostedResetFlow.click(card.confirm, in: window)
        try flow.finishReset()
        XCTAssertEqual(try flow.kinds.grantIDs(), [ClaudeKindsFixture.refillGrant], "the changed pick, and only on confirm")
    }
}

extension HostedResetFlow {
    /// The layout of a card that asks the owner to pick a kind.
    func pickLayout(in window: NSWindow) -> CardLayout {
        CardLayout(window: window, title: ResetConfirmation.pickTitle(displayName: account.displayName))
    }

    /// The layout of a card with no list, such as a retry of the only kind.
    func plainLayout(in window: NSWindow) -> CardLayout {
        CardLayout(window: window, title: "")
    }
}

// MARK: - Confirming against the account as it is now

@MainActor
final class ResetConfirmationFlowTests: XCTestCase {
    private func started() throws -> HostedResetFlow {
        let flow = try HostedResetFlow.started()
        addTeardownBlock { await flow.cleanUp() }
        return flow
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = HostedResetFlow.host(view)
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    private func choice(_ kind: ResetKind.Key) -> ResetConfirmation.Choice {
        ResetConfirmation.Choice(kind: kind, label: kind == .full ? "Full reset" : "Testmodel reset", retrying: false)
    }

    /// A retry card left open past its 10 minutes sends nothing when
    /// confirmed, and never becomes a new attempt: not while the account
    /// waits for a fresh reading, and not after that reading lifts the hold.
    func testStaleRetryConfirmationSendsNothing() throws {
        let flow = try started()
        let a = flow.account
        let clock = flow.kinds.clock
        flow.kinds.http.enqueue(status: 503)
        try flow.kinds.enqueueReading()
        flow.model.confirmReset(a, choice: choice(.modelRefill))
        try flow.finishReset()
        XCTAssertEqual(flow.model.resetGates[a.id], .retryOnly(kind: .modelRefill, label: "Testmodel reset"))

        let window = host(flow.card())
        let card = flow.plainLayout(in: window)

        // The window ends; the read after the close fails, so the hold stays.
        flow.kinds.http.enqueue(status: 500)
        try HostedResetFlow.wait("the retry window to end") {
            _ = await clock.parkedSleep(interval: 600, number: 1)
            await clock.advance(by: 600)
            await flow.harness.waitForModel("the gate flipped") { $0.resetGates[a.id] == .awaitingReading }
            await waitUntil("the read after the close ran") { flow.kinds.usageReads == 3 }
            await clock.settle()
        }
        XCTAssertEqual(flow.model.resetGates[a.id], .awaitingReading)
        let sent = flow.kinds.http.requests.count

        try HostedResetFlow.click(card.confirm, in: window)
        XCTAssertNil(flow.model.resetTasks[a.id], "nothing started")
        XCTAssertEqual(flow.kinds.http.requests.count, sent, "nothing sent while waiting for a fresh reading")

        // A fresh reading lifts the hold; the stale card still sends nothing.
        try flow.kinds.enqueueReading()
        try HostedResetFlow.wait("a fresh reading") {
            await clock.advance(by: BackoffPolicy.errorCap + 1)
            flow.model.refreshAll()
            await flow.harness.waitForModel("a fresh reading lifted the gate") { $0.resetGates[a.id] == nil }
        }
        let afterRead = flow.kinds.http.requests.count
        try HostedResetFlow.click(card.confirm, in: window)
        XCTAssertNil(flow.model.resetTasks[a.id], "the stale retry is not a new attempt")
        XCTAssertEqual(flow.kinds.http.requests.count, afterRead)
        XCTAssertEqual(flow.kinds.postRequests.count, 1, "only the first send ever went out")

        // The same card confirmed while the retry was open does send it, so
        // the clicks above reached the card's confirm button.
        let fresh = try started()
        fresh.kinds.http.enqueue(status: 503)
        try fresh.kinds.enqueueReading()
        fresh.model.confirmReset(fresh.account, choice: choice(.modelRefill))
        try fresh.finishReset()
        fresh.kinds.enqueueResetAnswer()
        try fresh.kinds.enqueueReading()
        let open = host(fresh.card())
        try HostedResetFlow.click(fresh.plainLayout(in: open).confirm, in: open)
        try fresh.finishReset()
        XCTAssertEqual(fresh.kinds.postRequests.count, 2)
    }

    /// After an unanswered send, a reading that lists no reset at all (the
    /// provider dropped the block once the grant was spent) still leaves the
    /// retry offered by the row and the card, and the retry resends the
    /// same grant and request id.
    func testRetryStaysReachableWhenTheReadingListsNoKinds() throws {
        let flow = try started()
        let a = flow.account
        flow.kinds.http.enqueue(status: 503)
        flow.kinds.http.enqueue(status: 200, body: try ClaudeKindsFixture.body(
            withResetBlock: #"{"eligible":false,"ineligible_reason":"no_grant"}"#
        ))
        flow.model.confirmReset(a, choice: choice(.modelRefill))
        try flow.finishReset()
        try HostedResetFlow.wait("the read after the 503") {
            await flow.harness.waitForStatus("it lists no resets") { $0[a.id]?.status.resetCreditsAvailable == nil }
        }
        let gate = try XCTUnwrap(flow.model.resetGates[a.id])
        XCTAssertEqual(gate, .retryOnly(kind: .modelRefill, label: "Testmodel reset"))

        XCTAssertEqual(AccountRow.resetCount(credits: nil, gate: gate), 0, "the row keeps its resets column")
        XCTAssertNil(AccountRow.resetCount(credits: nil, gate: nil), "and has none without the retry")
        let offer = ResetOffer(count: 0, kinds: nil, dimmed: false, gate: gate, now: ClaudeKindsFixture.start)
        XCTAssertNil(offer.disabledReason, "the button and the menus offer the retry")
        XCTAssertEqual(offer.kinds.map(\.key), [.modelRefill], "on a line of its own")
        XCTAssertEqual(offer.enabledHelp, "Retry the earlier Testmodel reset")

        flow.kinds.enqueueResetAnswer()
        try flow.kinds.enqueueReading()
        let window = host(flow.card())
        try HostedResetFlow.click(flow.plainLayout(in: window).confirm, in: window)
        try flow.finishReset()

        XCTAssertEqual(try flow.kinds.grantIDs(), [ClaudeKindsFixture.refillGrant, ClaudeKindsFixture.refillGrant])
        let ids = try flow.kinds.requestIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "the retry is the same attempt")
        XCTAssertEqual(flow.model.resetNotices[a.id]?.text, "Testmodel reset used — limits refreshed",
                       "the kind is named from the gate once the reading has dropped it")
    }

    /// A failed read after an unanswered send dims the row; the retry is
    /// still offered, while a new attempt on a dimmed row is not.
    func testRetryIsNotGreyedByADimmedRow() {
        let zero = ResetKind(key: .modelRefill, label: "Testmodel reset", count: 0)
        let retry = ResetGate.retryOnly(kind: .modelRefill, label: "Testmodel reset")
        let now = ClaudeKindsFixture.start
        XCTAssertNil(ResetOffer(count: 0, kinds: [zero], dimmed: true, gate: retry, now: now).disabledReason)
        XCTAssertNil(ResetOffer(count: 0, kinds: nil, dimmed: true, gate: retry, now: now).disabledReason)
        XCTAssertEqual(ResetOffer(count: 1, kinds: [ResetKind(key: .full, label: "Full reset", count: 1)],
                                  dimmed: true, gate: nil, now: now).disabledReason,
                       "Refresh this account first")
    }

    /// A row with no kinds keeps its retry too, at whatever count it reads,
    /// and its card sends the retry, not a new attempt.
    func testRetryOnARowWithoutKinds() {
        let retry = ResetGate.retryOnly(kind: nil, label: nil)
        let now = ClaudeKindsFixture.start
        XCTAssertEqual(AccountRow.resetCount(credits: nil, gate: retry), 0)
        XCTAssertNil(ResetOffer(count: 0, kinds: nil, dimmed: false, gate: retry, now: now).disabledReason)
        XCTAssertNil(ResetOffer(count: 0, kinds: nil, dimmed: true, gate: retry, now: now).disabledReason)
        XCTAssertEqual(ResetOffer(count: 0, kinds: nil, dimmed: false, gate: nil, now: now).disabledReason,
                       "No resets available", "a new attempt at 0 is still refused")

        var confirmed: [ResetConfirmation.Choice] = []
        let card = ResetConfirmation(displayName: "Row", count: 0, windows: [], kinds: nil, gate: retry,
                                     onChoice: { confirmed.append($0) }, onCancel: {})
        card.onConfirm()
        XCTAssertEqual(confirmed, [ResetConfirmation.Choice(kind: nil, label: nil, retrying: true)])
    }

    /// With every kind at 0 and no attempt pending, a confirmed pick sends
    /// nothing and the row says why.
    func testNewAttemptRefusedWhenNothingIsSpendable() throws {
        let flow = try started()
        let a = flow.account
        flow.kinds.http.enqueue(status: 200, body: try ClaudeKindsFixture.body(
            withResetBlock: #"{"eligible":false,"ineligible_reason":"no_grant"}"#
        ))
        try HostedResetFlow.wait("a reading with nothing to spend") {
            await flow.kinds.clock.advance(by: BackoffPolicy.errorCap + 1)
            flow.model.refreshAll()
            await flow.harness.waitForStatus("no resets") { $0[a.id]?.status.resetCreditsAvailable == nil }
        }
        let sent = flow.kinds.http.requests.count
        flow.model.confirmReset(a, choice: choice(.modelRefill))
        flow.model.useReset(a, choice: .modelRefill)
        XCTAssertNil(flow.model.resetTasks[a.id])
        XCTAssertEqual(flow.kinds.http.requests.count, sent)
        XCTAssertEqual(flow.model.resetNotices[a.id]?.text, "No resets available")
    }
}
