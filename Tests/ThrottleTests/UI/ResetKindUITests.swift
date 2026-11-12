import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// The rules and words behind the kind lines, the Use reset button and the
/// confirmation on a row with reset kinds. Rendering is in
/// `PopupSnapshotTests`.
@MainActor
final class ResetKindUITests: XCTestCase {
    private let now = UIFixtures.now

    private let full2 = ResetKind(key: .full, label: "Full reset", count: 2)
    private let fable1 = ResetKind(key: .modelRefill, label: "Fable reset", count: 1)

    private func offer(_ kinds: [ResetKind]?, count: Int? = nil, dimmed: Bool = false, gate: ResetGate? = nil) -> ResetOffer {
        ResetOffer(count: count ?? kinds?.reduce(0) { $0 + $1.count } ?? 0, kinds: kinds, dimmed: dimmed, gate: gate, now: now)
    }

    private func status(_ kinds: [ResetKind]?, credits: Int? = nil) -> AccountStatus {
        AccountStatus(accountID: UUID(), provider: .anthropic, email: "kinds@example.com", windows: [],
                      fetchedAt: now, state: .ok, resetCreditsAvailable: credits, resetKinds: kinds)
    }

    // MARK: The button and the menus (ISC-401, ISC-402, ISC-403)

    func testButtonRuleByKinds() {
        let paused = ResetKind(key: .full, label: "Full reset", count: 1, reason: .paused)
        let atLimit = ResetKind(key: .modelRefill, label: "Fable reset", count: 1, reason: .usableOnlyAtLimit)
        let zero = ResetKind(key: .full, label: "Full reset", count: 0)
        let fableZero = ResetKind(key: .modelRefill, label: "Fable reset", count: 0)

        XCTAssertNil(offer([full2, fable1]).disabledReason, "spendable kinds")
        XCTAssertNil(offer([paused, fable1]).disabledReason, "one spendable kind is enough")
        XCTAssertEqual(offer([atLimit]).disabledReason, "Usable once you reach a limit", "one kind: its own reason")
        XCTAssertEqual(offer([paused, atLimit]).disabledReason, "No reset can be used right now")
        XCTAssertEqual(offer([zero, fableZero]).disabledReason, "No resets available")
        XCTAssertEqual(offer([zero]).disabledReason, "No resets available")
        XCTAssertEqual(offer([full2, fable1], dimmed: true).disabledReason, "Refresh this account first")
        XCTAssertEqual(offer([full2], gate: .awaitingReading).disabledReason, "Waiting for a fresh reading")
        // A pending retry is offered even when its kind reads 0 or blocked.
        let retry = ResetGate.retryOnly(kind: .full, label: "Full reset")
        XCTAssertNil(offer([zero, ResetKind(key: .modelRefill, label: "Fable reset", count: 1, reason: .paused)], gate: retry).disabledReason)
        XCTAssertNil(offer([fable1], gate: retry).disabledReason, "even when its kind is gone")
        XCTAssertEqual(offer([fable1], gate: retry).enabledHelp, "Retry the earlier Full reset")
    }

    func testRowsWithoutKindsKeepTheCountRule() {
        XCTAssertNil(offer(nil, count: 2).disabledReason)
        XCTAssertNil(offer([], count: 2).disabledReason)
        XCTAssertEqual(offer(nil, count: 0).disabledReason, "No resets available")
        XCTAssertEqual(offer(nil, count: 1, dimmed: true).disabledReason, "Refresh this account first")
        for (count, dimmed) in [(2, false), (0, false), (1, true)] {
            XCTAssertEqual(offer(nil, count: count, dimmed: dimmed).disabledReason,
                           ResetCreditsColumn.disabledReason(count: count, dimmed: dimmed))
        }
        XCTAssertEqual(offer(nil, count: 2).enabledHelp, "Spend one banked reset for this account")
    }

    func testLineReasons() {
        let soon = now.addingTimeInterval(2 * 3_600)
        let later = now.addingTimeInterval(3 * 86_400)
        let cases: [(ResetKind.Reason, String)] = [
            (.usableOnlyAtLimit, "Usable once you reach a limit"),
            (.nothingToGiveBack, "No Fable usage to give back"),
            (.paused, "Paused"),
            (.notStarted(startsAt: later), "Starts \(Formatting.resetStamp(later))"),
            (.cooldown(until: soon), "On cooldown until \(Formatting.clockTime(soon))"),
            (.notUsableNow, "Not usable right now"),
            (.noneLeft, "None left"),
        ]
        for (reason, words) in cases {
            let kind = ResetKind(key: .modelRefill, label: "Fable reset", count: 1, reason: reason)
            XCTAssertEqual(offer([kind]).reason(for: kind), words)
        }
        XCTAssertEqual(offer([ResetKind(key: .full, label: "Full reset", count: 0)]).reason(for: ResetKind(key: .full, label: "Full reset", count: 0)), "None left")
        let retry = offer([full2, fable1], gate: .retryOnly(kind: .full, label: "Full reset"))
        XCTAssertNil(retry.reason(for: full2))
        XCTAssertEqual(retry.reason(for: fable1), "Finish the earlier reset first")
        XCTAssertEqual(offer([full2], gate: .awaitingReading).reason(for: full2), "Waiting for a fresh reading")
    }

    func testSameKindTwiceIsOneLine() {
        let merged = ResetOffer.merged([
            ResetKind(key: .full, label: "Full reset", count: 2, reason: .paused),
            ResetKind(key: .full, label: "Full reset", count: 1),
            fable1,
        ])
        XCTAssertEqual(merged.map(\.key), [.full, .modelRefill])
        XCTAssertEqual(merged.first?.count, 3)
        XCTAssertTrue(merged.first?.isSpendable ?? false, "spendable when either is")
    }

    // MARK: VoiceOver (ISC-420)

    func testKindAccessibility() {
        let paused = ResetKind(key: .modelRefill, label: "Fable reset", count: 1, reason: .paused)
        XCTAssertEqual(offer([full2, fable1]).columnAccessibilityLabel, "Manual resets: 2 Full reset, 1 Fable reset")
        XCTAssertEqual(offer([full2, paused]).lineAccessibilityLabel(for: paused), "1 Fable reset, unavailable: Paused")
        XCTAssertEqual(offer([full2, paused]).lineAccessibilityLabel(for: full2), "2 Full reset")
        XCTAssertEqual(ResetKindPicker.accessibilityLabel(for: full2, reason: nil, picked: true), "2 Full reset, picked")
        XCTAssertEqual(ResetKindPicker.accessibilityLabel(for: paused, reason: "Paused", picked: false), "1 Fable reset, unavailable: Paused")

        let success = ResetMessages.notice(for: .outcome(.reset), providerName: "Claude", now: now, kindLabel: "Full reset")!
        XCTAssertEqual(ResetMessages.announcement(for: success, kindLabel: "Full reset"), "Full reset used — limits refreshed")
        let failed = ResetMessages.notice(for: .unreachable, providerName: "Claude", now: now, kindLabel: "Fable reset")!
        XCTAssertEqual(ResetMessages.announcement(for: failed, kindLabel: "Fable reset"),
                       "Fable reset: Couldn't reach Claude — check your connection and try again")
        XCTAssertEqual(ResetMessages.announcement(for: failed, kindLabel: nil), failed.text, "no kind, no prefix")
    }

    // MARK: Words (ISC-405, ISC-407, ISC-412, ISC-417)

    func testConfirmationTitles() {
        XCTAssertEqual(ResetConfirmation.title(kind: full2, displayName: "Work"), "Use 1 of 2 Full resets for Work?")
        XCTAssertEqual(ResetConfirmation.title(kind: fable1, displayName: "Work"), "Use 1 of 1 Fable reset for Work?")
        XCTAssertEqual(ResetConfirmation.title(kind: ResetKind(key: .other, label: "Bonus", count: 3), displayName: "Work"),
                       "Use 1 of 3 Bonus for Work?", "a label that is not \"… reset\" is not guessed at")
        XCTAssertEqual(ResetConfirmation.retryTitle(label: "Full reset", displayName: "Work"), "Retry Full reset for Work?")
        XCTAssertEqual(ResetConfirmation.title(count: 2, displayName: "Work"), "Use 1 of 2 resets for Work?", "no kinds: as before")
    }

    func testModelRefillLineUsesTheRowsWindowNames() {
        let windows = [
            UIFixtures.window("7d", label: "Weekly", used: 40),
            UIFixtures.window(UsageWindow.scopedPrefix + "Quill", label: "Quill", used: 70),
        ]
        XCTAssertEqual(ResetConfirmation.modelRefillLine(kindLabel: "Quill reset", windows: windows),
                       "Refills 7-day Quill and returns its share to the 7-day limit. Other weekly usage stays as it is.")
        XCTAssertEqual(ResetConfirmation.modelRefillLine(kindLabel: "Model reset", windows: windows),
                       "Refills 7-day Quill and returns its share to the 7-day limit. Other weekly usage stays as it is.",
                       "the only model window, when the label names none")
        let noModel = ResetConfirmation.modelRefillLine(kindLabel: "Model reset", windows: [windows[0]])
        XCTAssertFalse(noModel.contains("Quill"))
    }

    func testSuccessNoteNamesTheKind() {
        func success(_ label: String?) -> String? {
            ResetMessages.notice(for: .outcome(.reset), providerName: "Claude", now: now, kindLabel: label)?.text
        }
        XCTAssertEqual(success("Full reset"), "Full reset used — limits refreshed")
        XCTAssertEqual(success("Reset"), "Reset used — limits refreshed")
        XCTAssertEqual(success(nil), "Reset used — limits refreshed")
    }

    // MARK: Confirming against the latest reading (ISC-410, ISC-518)

    private func choice(_ kind: ResetKind.Key?, retrying: Bool = false) -> ResetConfirmation.Choice {
        ResetConfirmation.Choice(kind: kind, label: kind == .full ? "Full reset" : "Fable reset", retrying: retrying)
    }

    func testChosenKindGoneAtConfirmSendsNothing() {
        let blocked = ResetKind(key: .full, label: "Full reset", count: 2, reason: .paused)
        let zero = ResetKind(key: .full, label: "Full reset", count: 0)
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full), status: status([full2, fable1]), gate: nil),
                       .send(kind: .full, retrying: false))
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.modelRefill), status: status([full2, fable1]), gate: nil),
                       .send(kind: .modelRefill, retrying: false), "the kind picked, never another")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full), status: status([fable1]), gate: nil),
                       .hold(.noneLeft, label: "Full reset"), "gone")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full), status: status([zero, fable1]), gate: nil),
                       .hold(.noneLeft, label: "Full reset"), "at 0")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full), status: status([blocked, fable1]), gate: nil),
                       .hold(.paused, label: "Full reset"), "blocked")
        XCTAssertEqual(ResetConfirmation.heldNotice(for: .hold(.noneLeft, label: "Full reset"), providerName: "Claude", now: now)?.text,
                       "No resets available")
        XCTAssertEqual(ResetConfirmation.heldNotice(for: .hold(.paused, label: "Full reset"), providerName: "Claude", now: now)?.text,
                       "Paused")
        XCTAssertNil(ResetConfirmation.heldNotice(for: .hold(nil, label: nil), providerName: "Claude", now: now))
        // A no-kinds card whose account has since reported kinds: pick again.
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(nil), status: status([full2]), gate: nil), .hold(nil, label: nil))
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(nil), status: status(nil, credits: 2), gate: nil),
                       .send(kind: nil, retrying: false), "a row with no kinds sends as before")
    }

    func testStaleRetryConfirmationSendsNothing() {
        let retry = ResetGate.retryOnly(kind: .full, label: "Full reset")
        let gone = status([fable1])
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full, retrying: true), status: gone, gate: retry),
                       .send(kind: .full, retrying: true), "the retry goes even with its kind gone")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full, retrying: true), status: gone, gate: .awaitingReading),
                       .hold(nil, label: nil), "refused or past its lifetime: nothing, and no new attempt")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full, retrying: true), status: status([full2]), gate: nil),
                       .hold(nil, label: nil), "settled meanwhile: nothing; a new card is a new attempt")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.modelRefill, retrying: true), status: gone, gate: retry),
                       .hold(nil, label: nil), "a retry is only of its own kind")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.full), status: status([full2]), gate: .awaitingReading),
                       .hold(nil, label: nil), "a new attempt waits for the fresh reading")
        XCTAssertEqual(ResetConfirmation.outcome(of: choice(.modelRefill), status: status([full2, fable1]), gate: retry),
                       .hold(nil, label: nil), "no other kind while a retry is pending")
    }

    // MARK: Keyboard (ISC-419)

    func testArrowsMoveOnlyBetweenPickableKinds() {
        let pickable: [ResetKind.Key] = [.full, .modelRefill]
        XCTAssertEqual(ResetKindPicker.move(from: nil, by: 1, in: pickable), .full)
        XCTAssertEqual(ResetKindPicker.move(from: nil, by: -1, in: pickable), .modelRefill)
        XCTAssertEqual(ResetKindPicker.move(from: .full, by: 1, in: pickable), .modelRefill, "the blocked kind between is skipped")
        XCTAssertEqual(ResetKindPicker.move(from: .modelRefill, by: 1, in: pickable), .full)
        XCTAssertEqual(ResetKindPicker.move(from: .full, by: -1, in: pickable), .modelRefill)
        XCTAssertNil(ResetKindPicker.move(from: nil, by: 1, in: []), "nothing to pick")
    }

    /// The real card, hosted in a window: Return and Escape each close it
    /// before and after a pick, and neither confirms.
    func testReturnAndEscapeNeverConfirm() throws {
        for picked in [nil, ResetKind.Key.full] {
            for key in [(characters: "\r", code: UInt16(36)), (characters: "\u{1b}", code: UInt16(53))] {
                var choices: [ResetConfirmation.Choice] = []
                var cancels = 0
                let card = ResetConfirmation(
                    displayName: "Work", count: 3, windows: [], kinds: [full2, fable1], gate: nil, now: now,
                    picked: picked, onChoice: { choices.append($0) }, onCancel: { cancels += 1 }
                )
                let hosting = NSHostingView(rootView: card)
                // Off screen: it needs to be key, not seen.
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: key.characters, charactersIgnoringModifiers: key.characters,
                    isARepeat: false, keyCode: key.code
                ))
                if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertEqual(choices, [], "key \(key.code), picked \(String(describing: picked)): nothing confirmed")
                XCTAssertEqual(cancels, 1, "key \(key.code), picked \(String(describing: picked)): the card closed")
            }
        }
    }
}
