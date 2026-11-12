import XCTest
@testable import Throttle

/// The app's side of the two answers an adapter gives without sending
/// anything, and the attempt bookkeeping for a chosen kind.
final class ResetKindMessagesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func text(_ result: ResetResult, kindLabel: String? = nil) -> String? {
        ResetMessages.notice(for: result, providerName: "Claude", now: now, kindLabel: kindLabel)?.text
    }

    func testNeedsFreshReadingWording() {
        XCTAssertEqual(text(.outcome(.needsFreshReading)), "Getting the latest reset counts — try again in a moment")
        XCTAssertEqual(ResetMessages.notice(for: .outcome(.needsFreshReading), providerName: "Claude", now: now)?.kind, .failure)
    }

    func testBlockedWordingPerReason() {
        let soon = now.addingTimeInterval(2 * 3_600)
        let later = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(text(.outcome(.blocked(.usableOnlyAtLimit))), "Usable once you reach a limit")
        XCTAssertEqual(text(.outcome(.blocked(.paused))), "Paused")
        XCTAssertEqual(text(.outcome(.blocked(.notUsableNow))), "Not usable right now")
        XCTAssertEqual(text(.outcome(.blocked(.noneLeft))), "No resets available")
        XCTAssertEqual(text(.outcome(.blocked(.cooldown(until: soon)))), "On cooldown until \(Formatting.clockTime(soon))")
        XCTAssertEqual(text(.outcome(.blocked(.cooldown(until: nil)))), "On cooldown")
        XCTAssertEqual(text(.outcome(.blocked(.notStarted(startsAt: later)))), "Starts \(Formatting.resetStamp(later))")
        XCTAssertEqual(text(.outcome(.blocked(.nothingToGiveBack)), kindLabel: "Testmodel reset"), "No Testmodel usage to give back")
    }

    func testBlockedWordingCarriesNoProviderText() {
        for reason: ResetKind.Reason in [.paused, .notUsableNow, .usableOnlyAtLimit, .noneLeft, .nothingToGiveBack] {
            let words = text(.outcome(.blocked(reason)), kindLabel: "Testmodel reset") ?? ""
            for code in ["_", "cedar", "juniper", "grant", "ineligible"] {
                XCTAssertFalse(words.contains(code), "\(reason): \(words)")
            }
        }
    }

    func testOnlyNeedsFreshReadingWantsARead() {
        XCTAssertTrue(ResetResult.outcome(.needsFreshReading).wantsUsageRead)
        XCTAssertFalse(ResetResult.outcome(.blocked(.paused)).wantsUsageRead)
        XCTAssertFalse(ResetResult.outcome(.blocked(.noneLeft)).wantsUsageRead)
    }

    func testNothingSentEndsAFreshAttemptButKeepsAnUncertainOne() {
        XCTAssertEqual(ResetAttempts.ending(of: .outcome(.blocked(.paused))), .refused)
        XCTAssertEqual(ResetAttempts.ending(of: .outcome(.needsFreshReading)), .refused)

        let account = UUID()
        var attempts = ResetAttempts()
        let fresh = attempts.attemptID(for: account, choice: .full)
        attempts.finish(account, with: .outcome(.blocked(.paused)))
        XCTAssertNotEqual(attempts.attemptID(for: account, choice: .full), fresh, "nothing was sent, so the next click is new")

        var uncertain = ResetAttempts()
        let first = uncertain.attemptID(for: account, choice: .full)
        uncertain.finish(account, with: .unreachable)
        uncertain.finish(account, with: .outcome(.needsFreshReading))
        XCTAssertEqual(uncertain.attemptID(for: account, choice: .full), first, "an uncertain send stays pending")
    }

    func testAnAttemptKeepsItsKind() {
        let account = UUID()
        var attempts = ResetAttempts()
        let first = attempts.attemptID(for: account, choice: .full)
        attempts.finish(account, with: .unreachable)
        XCTAssertNil(attempts.attemptID(for: account, choice: .modelRefill), "another kind gets no id while one is pending")
        XCTAssertNil(attempts.attemptID(for: account, choice: nil))
        XCTAssertEqual(attempts.attemptID(for: account, choice: .full), first, "the pending attempt is unchanged")
        XCTAssertEqual(attempts.attemptID(for: account), first)
        attempts.finish(account, with: .outcome(.reset))
        XCTAssertNotNil(attempts.attemptID(for: account, choice: .modelRefill), "once it ends, any kind can start")
    }
}
