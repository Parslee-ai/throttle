import SwiftUI
import XCTest
@testable import Throttle

/// The words, the enablement rule, and the attempt ids behind the Use reset
/// button. Rendering is in `PopupSnapshotTests`.
@MainActor
final class ResetUITests: XCTestCase {
    private let now = UIFixtures.now

    private func text(_ result: ResetResult, provider: String = "Codex") -> String? {
        ResetMessages.notice(for: result, providerName: provider, now: now)?.text
    }

    // MARK: Messages (group A wording)

    func testEveryResultHasGroupAWording() {
        let inAnHour = now.addingTimeInterval(3_600)
        let clock = Formatting.clockTime(inAnHour)
        XCTAssertEqual(text(.outcome(.reset)), "Reset used — limits refreshed")
        XCTAssertEqual(text(.outcome(.nothingToReset)), "Nothing to reset right now — your reset was not used")
        XCTAssertEqual(text(.outcome(.noCredit)), "No resets available")
        XCTAssertEqual(text(.outcome(.cooldown(until: inAnHour))), "Reset on cooldown until \(clock)")
        XCTAssertEqual(text(.outcome(.notAvailable)), "Resets aren't available for this account right now")
        XCTAssertEqual(text(.rateLimited(until: inAnHour), provider: "Claude"), "Claude is limiting requests — try again at \(clock)")
        XCTAssertEqual(text(.providerError(status: 503)), "Codex had a problem (HTTP 503). Try again — a retry never spends a second reset.")
        XCTAssertEqual(text(.providerError(status: 500), provider: "Claude"), "Claude had a problem (HTTP 500). Try again — a retry never spends a second reset.")
        XCTAssertEqual(text(.providerError(status: 404)), "Codex couldn't use the reset (HTTP 404). Nothing was changed.")
        XCTAssertEqual(text(.unreachable), "Couldn't reach Codex — check your connection and try again")
        XCTAssertEqual(text(.outcome(.unexpected)), "Unexpected answer from Codex")
        XCTAssertEqual(text(.unexpected), "Unexpected answer from Codex")
        XCTAssertEqual(text(.unsupported), "Resets aren't available for this account right now")
        XCTAssertEqual(text(.forbidden(reason: "Not allowed for this organization.")), "Not allowed for this organization.")
    }

    func testOnlySuccessFades() {
        XCTAssertEqual(ResetMessages.notice(for: .outcome(.reset), providerName: "Codex", now: now)?.kind, .success)
        for result: ResetResult in [.outcome(.nothingToReset), .outcome(.noCredit), .unreachable, .providerError(status: 500)] {
            XCTAssertEqual(ResetMessages.notice(for: result, providerName: "Codex", now: now)?.kind, .failure, "\(result)")
        }
    }

    func testCooldownInThePastOrUnknownIsTheGenericMessage() {
        XCTAssertEqual(text(.outcome(.cooldown(until: now.addingTimeInterval(-60)))), ResetMessages.notAvailable)
        XCTAssertEqual(text(.outcome(.cooldown(until: nil))), ResetMessages.notAvailable)
    }

    func testSignInAndSecondClickShowNoMessage() {
        XCTAssertNil(text(.needsLogin), "the row's own sign-in state says it")
        XCTAssertNil(text(.alreadyRunning))
    }

    func testMessagesAreRedactedFlattenedAndCapped() {
        let hostile = "denied\nBearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig\u{0007}\t sk-live-abcdefgh "
            + String(repeating: "x", count: 1_000)
        let shown = text(.forbidden(reason: hostile)) ?? ""
        XCTAssertLessThanOrEqual(shown.count, ResetMessages.maxLength)
        XCTAssertFalse(shown.contains("eyJ"))
        XCTAssertFalse(shown.contains("sk-live"))
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertFalse(shown.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertTrue(shown.hasPrefix("denied [redacted]"))
    }

    // MARK: Attempt ids

    func testARetryAfterNoAnswerReusesTheAttemptAndADefinitiveAnswerEndsIt() {
        var attempts = ResetAttempts()
        let account = UUID()
        let first = attempts.attemptID(for: account)
        attempts.finish(account, with: .unreachable)
        XCTAssertEqual(attempts.attemptID(for: account), first, "couldn't reach: the retry is the same attempt")
        attempts.finish(account, with: .outcome(.nothingToReset))
        XCTAssertNotEqual(attempts.attemptID(for: account), first, "a definitive answer ends the attempt")
        let other = UUID()
        XCTAssertNotEqual(attempts.attemptID(for: other), attempts.attemptID(for: account), "ids are per account")
    }

    // MARK: Enablement and confirmation

    func testButtonEnablementRule() {
        XCTAssertNil(ResetCreditsColumn.disabledReason(count: 2, dimmed: false))
        XCTAssertEqual(ResetCreditsColumn.disabledReason(count: 0, dimmed: false), "No resets available")
        XCTAssertEqual(ResetCreditsColumn.disabledReason(count: 1, dimmed: true), "Refresh this account first")
    }

    func testConfirmationNamesTheAccountTheCountAndEachWindow() {
        XCTAssertEqual(ResetConfirmation.title(count: 2, displayName: "work@example.com"), "Use 1 of 2 resets for work@example.com?")
        XCTAssertEqual(ResetConfirmation.title(count: 1, displayName: "Work"), "Use 1 of 1 reset for Work?")
        let lines = ResetConfirmation.windowLines([
            UIFixtures.window("5h", label: "5h", used: 70),
            UIFixtures.window("7d", label: "Weekly", used: 10),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("30% left"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("90% left"), lines[1])
    }

    // MARK: Fill animation

    /// The frames `PopupSnapshotTests` renders: progress 0, 0.25, 0.5, 0.75
    /// and 1 through the fill animation's own ease-in-out curve, from 12% to
    /// 100% left. At least three in-between widths, strictly growing.
    func testFillAnimationFramesSlideThroughDistinctWidths() {
        let widths = ResetAnimationFrames.progress.map {
            UsageBar.filledWidth(fraction: ResetAnimationFrames.fraction(at: $0), width: PopupMetrics.columnWidth)
        }
        XCTAssertEqual(widths.first ?? 0, PopupMetrics.columnWidth * 0.12, accuracy: 0.5)
        XCTAssertEqual(widths.last ?? 0, PopupMetrics.columnWidth, accuracy: 0.5)
        for (a, b) in zip(widths, widths.dropFirst()) {
            XCTAssertLessThan(a, b)
        }
        XCTAssertEqual(Set(widths.dropFirst().dropLast()).count, 3)
        XCTAssertEqual(UsageBar.fillDuration, 0.8)
    }
}

/// The animation frames both the frame test and the snapshot test use.
enum ResetAnimationFrames {
    static let progress: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let from = 0.12
    static let to = 1.0

    /// The remaining fraction SwiftUI draws at `progress` of the fill
    /// animation. The fill's width is linear in the fraction, so interpolating
    /// the frame width (what `.animation` does) and interpolating the fraction
    /// draw the same bar.
    static func fraction(at progress: Double, from: Double = Self.from) -> Double {
        from + (to - from) * UnitCurve.easeInOut.value(at: progress)
    }
}
