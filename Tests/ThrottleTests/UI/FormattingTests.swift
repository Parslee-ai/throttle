import XCTest
@testable import Throttle

final class FormattingTests: XCTestCase {
    private let now = UIFixtures.now

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let enUS = Locale(identifier: "en_US")

    // MARK: Percentages

    func testPercentIsAlwaysWhatIsLeft() {
        XCTAssertEqual(Formatting.percentText(used: 42.4), "58%")
        XCTAssertEqual(Formatting.percentText(used: 0), "100%")
        XCTAssertEqual(Formatting.percentText(used: 100), "0%")
        XCTAssertEqual(Formatting.percentText(used: 140), "0%")
        XCTAssertEqual(Formatting.percentText(used: -5), "100%")
        XCTAssertEqual(Formatting.remainingPercent(used: 11), 89)
        XCTAssertEqual(Formatting.remainingPercent(used: 99.6), 0)
        XCTAssertEqual(Formatting.remainingPercent(used: 99.4), 1)
        XCTAssertEqual(Formatting.remainingPercent(used: .nan), 100)
    }

    // MARK: Window labels

    func testLongLabelsAreDerivedFromTheWindowLength() {
        XCTAssertEqual(Formatting.longLabel(for: UIFixtures.window("5h", label: "5h", used: 0, seconds: 18_000)), "5-hour limit")
        XCTAssertEqual(Formatting.longLabel(for: UIFixtures.window("7d", label: "Weekly", used: 0, seconds: 604_800)), "7-day limit")
        XCTAssertEqual(Formatting.longLabel(for: UIFixtures.window("3h", label: "3h", used: 0, seconds: 10_800)), "3-hour limit")
        XCTAssertEqual(Formatting.longLabel(for: UIFixtures.window("2d", label: "2d", used: 0, seconds: 172_800)), "2-day limit")
        XCTAssertEqual(Formatting.longLabel(for: UIFixtures.window("x", label: "x", used: 0, seconds: 90_000)), "25-hour limit")
    }

    /// Model-scoped windows take the model name from the payload's label;
    /// nothing here knows a model name.
    func testLongLabelForAModelScopedWindowUsesThePayloadName() {
        let weekly = UIFixtures.window(UsageWindow.scopedPrefix + "Fable 5", label: "Fable 5", used: 0, seconds: 604_800)
        XCTAssertEqual(Formatting.longLabel(for: weekly), "7-day Fable 5")
        let daily = UIFixtures.window(UsageWindow.scopedPrefix + "Zed", label: "Zed", used: 0, seconds: 86_400)
        XCTAssertEqual(Formatting.longLabel(for: daily), "1-day Zed")
        let hourly = UIFixtures.window(UsageWindow.scopedPrefix + "Zed", label: "Zed", used: 0, seconds: 18_000)
        XCTAssertEqual(Formatting.longLabel(for: hourly), "5-hour Zed")
    }

    func testLanesKeepTheirOwnLabel() {
        let lane = UIFixtures.window("lane:spark-7d", label: "Spark Weekly", used: 0, seconds: 604_800)
        XCTAssertEqual(Formatting.longLabel(for: lane), "Spark Weekly")
    }

    func testShortLabels() {
        XCTAssertEqual(Formatting.shortLabel(for: UIFixtures.window("5h", label: "5h", used: 0, seconds: 18_000)), "5h")
        XCTAssertEqual(Formatting.shortLabel(for: UIFixtures.window("7d", label: "Weekly", used: 0, seconds: 604_800)), "WK")
        XCTAssertEqual(Formatting.shortLabel(for: UIFixtures.window("3h", label: "3h", used: 0, seconds: 10_800)), "3h")
        XCTAssertEqual(Formatting.shortLabel(for: UIFixtures.window("2d", label: "2d", used: 0, seconds: 172_800)), "2d")
        XCTAssertEqual(Formatting.shortLabel(for: UIFixtures.window("scoped:Fable", label: "Fable", used: 0)), "FB")
    }

    func testModelTagIsFirstLetterAndFirstFollowingConsonant() {
        XCTAssertEqual(Formatting.modelTag("Fable"), "FB")
        XCTAssertEqual(Formatting.modelTag("Fable 5"), "FB")
        XCTAssertEqual(Formatting.modelTag("Opus"), "OP")
        XCTAssertEqual(Formatting.modelTag("Sonnet"), "SN")
        XCTAssertEqual(Formatting.modelTag("Haiku"), "HK")
        XCTAssertEqual(Formatting.modelTag("Claude Opus"), "CL")
        // `y` counts as a vowel; digits and spaces are skipped.
        XCTAssertEqual(Formatting.modelTag("Ayo 9 Z"), "AZ")
        // No consonant after the first letter: the first two letters.
        XCTAssertEqual(Formatting.modelTag("Aeio"), "AE")
        XCTAssertEqual(Formatting.modelTag("x"), "X")
    }

    // MARK: Window order

    func testPopupOrderIsScopedThenSessionThenWeeklyThenTheRest() {
        let windows = [
            UIFixtures.window("5h", label: "5h", used: 0, seconds: 18_000),
            UIFixtures.window("7d", label: "Weekly", used: 0, seconds: 604_800),
            UIFixtures.window("30d", label: "30d", used: 0, seconds: 2_592_000),
            UIFixtures.window("scoped:Fable", label: "Fable", used: 0),
            UIFixtures.window("lane:spark-5h", label: "Spark 5h", used: 0, seconds: 18_000),
        ]
        XCTAssertEqual(Formatting.popupOrder(windows).map(\.key), ["scoped:Fable", "5h", "7d", "30d"])
        XCTAssertEqual(Formatting.barOrder(windows).map(\.key), ["5h", "7d", "30d", "scoped:Fable"])
    }

    func testOrderWithAWeeklyWindowOnly() {
        let windows = [UIFixtures.window("7d", label: "Weekly", used: 0, seconds: 604_800)]
        XCTAssertEqual(Formatting.popupOrder(windows).map(\.key), ["7d"])
        XCTAssertEqual(Formatting.barOrder(windows).map(\.key), ["7d"])
    }

    // MARK: Reset line

    func testResetUsesTheLargestWholeUnitThenAStamp() {
        let fiveDays = now.addingTimeInterval(5 * 86_400 + 3 * 3600)
        let reset = Formatting.resetText(resetsAt: fiveDays, now: now, calendar: utc, locale: enUS)
        XCTAssertEqual(reset.relative, "in 5 days")
        XCTAssertEqual(reset.stamp, Formatting.resetStamp(fiveDays, calendar: utc, locale: enUS))
        XCTAssertEqual(reset.line, "in 5 days · " + reset.stamp!)
        XCTAssertTrue(reset.isScheduled)
    }

    func testRelativeResetUnits() {
        XCTAssertEqual(Formatting.relativeReset(86_400), "in 1 day")
        XCTAssertEqual(Formatting.relativeReset(2 * 86_400 - 1), "in 1 day")
        XCTAssertEqual(Formatting.relativeReset(10 * 3600 + 59 * 60), "in 10 hours")
        XCTAssertEqual(Formatting.relativeReset(3600), "in 1 hour")
        XCTAssertEqual(Formatting.relativeReset(3599), "in 60 minutes")
        XCTAssertEqual(Formatting.relativeReset(12 * 60), "in 12 minutes")
        XCTAssertEqual(Formatting.relativeReset(30), "in 1 minute")
        XCTAssertEqual(Formatting.relativeReset(61), "in 2 minutes")
    }

    func testResetStampIsMonthDayAnd24HourTime() {
        // 2027-01-15 08:00:00 UTC.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Formatting.resetStamp(date, calendar: utc, locale: enUS), "01/15, 08:00")
        let evening = date.addingTimeInterval(12 * 3600 + 59 * 60)
        XCTAssertEqual(Formatting.resetStamp(evening, calendar: utc, locale: enUS), "01/15, 20:59")
    }

    func testResetPastAndMissing() {
        let past = Formatting.resetText(resetsAt: now.addingTimeInterval(-5), now: now)
        XCTAssertEqual(past.line, "resetting now")
        XCTAssertNil(past.stamp)

        let missing = Formatting.resetText(resetsAt: nil, now: now)
        XCTAssertEqual(missing.line, "No reset pending")
        XCTAssertFalse(missing.isScheduled)
    }

    func testDurationRoundsMinutesUp() {
        XCTAssertEqual(Formatting.durationText(90), "2m")
        XCTAssertEqual(Formatting.durationText(45 * 60), "45m")
        XCTAssertEqual(Formatting.durationText(3 * 86_400 + 2 * 3600), "3d 2h")
    }

    func testAgePhrase() {
        XCTAssertEqual(Formatting.agePhrase(since: now.addingTimeInterval(-12 * 60), now: now), "updated 12m ago")
        XCTAssertEqual(Formatting.agePhrase(since: now.addingTimeInterval(-10), now: now), "updated just now")
    }

    // MARK: Plan

    func testPlanTextIsTidied() {
        XCTAssertEqual(Formatting.planText("max"), "Max")
        XCTAssertEqual(Formatting.planText("pro"), "Pro")
        XCTAssertEqual(Formatting.planText("pro_20x"), "Pro 20x")
        XCTAssertEqual(Formatting.planText("team-plus__x"), "Team plus x")
        XCTAssertNil(Formatting.planText(nil))
        XCTAssertNil(Formatting.planText(""))
        XCTAssertNil(Formatting.planText("_-"))
    }

    // MARK: Bar label

    func testBarLabelIsNumberThenTaggedWindows() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 0),
            UIFixtures.window("7d", label: "Weekly", used: 11),
            UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 21),
        ])
        let label = Formatting.barLabel(account: account, index: 1, cached: cached, now: now)
        XCTAssertEqual(label.plainText, "1: 5h 100% / WK 89% / FB 79%")
        XCTAssertEqual(label.symbolName, Provider.anthropic.symbolName)
        XCTAssertEqual(label.prefix, "1: ")
        XCTAssertEqual(label.segments.map(\.band), [.normal, .normal, .normal])
        XCTAssertFalse(label.dimmed)
        XCTAssertFalse(label.isTruncated)
        XCTAssertFalse(label.plainText.contains("me@example.com"))
    }

    func testBarLabelSegmentsCarryTheirBand() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 85),
            UIFixtures.window("7d", label: "Weekly", used: 100),
            UIFixtures.window(UsageWindow.scopedPrefix + "Opus", label: "Opus", used: 79),
        ])
        let label = Formatting.barLabel(account: account, index: 2, cached: cached, now: now)
        XCTAssertEqual(label.plainText, "2: 5h 15% / WK 0% / OP 21%")
        XCTAssertEqual(label.segments.map(\.band), [.warning, .critical, .normal])
    }

    func testBarLabelForTenthAccountWithThreeFullWindowsStaysShort() {
        let account = UIFixtures.account("someone.with.a.very.long.name@example.com", nickname: "A very long nickname for work")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 0),
            UIFixtures.window("7d", label: "Weekly", used: 0),
            UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 0),
        ])
        let label = Formatting.barLabel(account: account, index: 10, cached: cached, now: now)
        XCTAssertEqual(label.plainText, "10: 5h 100% / WK 100% / FB 100%")
        XCTAssertLessThanOrEqual(label.plainText.count, 32)
    }

    /// ISC-115: more windows than fit keep whole segments and end with " …".
    func testBarLabelDropsWholeSegmentsPastTheBudget() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 0),
            UIFixtures.window("7d", label: "Weekly", used: 0),
            UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 0),
            UIFixtures.window(UsageWindow.scopedPrefix + "Opus", label: "Opus", used: 0),
            UIFixtures.window(UsageWindow.scopedPrefix + "Sonnet", label: "Sonnet", used: 0),
        ])
        let label = Formatting.barLabel(account: account, index: 12, cached: cached, now: now)
        XCTAssertTrue(label.isTruncated)
        XCTAssertLessThanOrEqual(label.plainText.count, Formatting.barCharacterBudget, label.plainText)
        XCTAssertEqual(label.plainText, "12: 5h 100% / WK 100% / FB 100% …")
        XCTAssertFalse(label.plainText.contains("\n"))
    }

    /// ISC-73: per-model lanes stay in the detail window; the bar shows only
    /// the primary windows.
    func testBarLabelOmitsLaneWindows() {
        let account = UIFixtures.account("me@example.com", provider: .openai)
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 20),
            UIFixtures.window("7d", label: "Weekly", used: 30),
            UIFixtures.window("lane:spark-5h", label: "Spark 5h", used: 99),
            UIFixtures.window("lane:spark-7d", label: "Spark Weekly", used: 98),
        ])
        let label = Formatting.barLabel(account: account, index: 3, cached: cached, now: now)
        XCTAssertEqual(label.plainText, "3: 5h 80% / WK 70%")
        XCTAssertFalse(label.plainText.contains("Spark"))
    }

    func testBarLabelStateMarkersKeepTheNumber() {
        let account = UIFixtures.account("me@example.com", provider: .openai)
        let needsLogin = UIFixtures.cached(for: account, windows: [], state: .needsLogin)
        XCTAssertEqual(Formatting.barLabel(account: account, index: 1, cached: needsLogin, now: now).plainText, "1: ⚠︎ login")

        let until = now.addingTimeInterval(1800)
        let limited = UIFixtures.cached(for: account, windows: [], state: .rateLimited(until: until))
        XCTAssertEqual(
            Formatting.barLabel(account: account, index: 1, cached: limited, now: now).plainText,
            "1: ⏳ retry \(Formatting.clockTime(until))"
        )

        let forbidden = UIFixtures.cached(for: account, windows: [], state: .forbidden("OAuth authentication is currently not allowed for this organization."))
        let forbiddenLabel = Formatting.barLabel(account: account, index: 1, cached: forbidden, now: now)
        XCTAssertEqual(forbiddenLabel.plainText, "1: 🔒 sign in again")
        XCTAssertEqual(forbiddenLabel.segments.first?.band, .warning)
        XCTAssertFalse(forbiddenLabel.dimmed)
        XCTAssertFalse(forbiddenLabel.plainText.contains("organization"), "the provider's message stays out of the bar")

        let empty = Formatting.barLabel(account: account, index: 1, cached: nil, now: now)
        XCTAssertEqual(empty.plainText, "1: …")
        XCTAssertTrue(empty.dimmed)

        let failed = UIFixtures.cached(for: account, windows: [], state: .error("Timed out"))
        let failedLabel = Formatting.barLabel(account: account, index: 1, cached: failed, now: now)
        XCTAssertEqual(failedLabel.plainText, "1: ⚠︎ error")
        XCTAssertTrue(failedLabel.dimmed)

        let blank = UIFixtures.cached(for: account, windows: [])
        XCTAssertEqual(Formatting.barLabel(account: account, index: 1, cached: blank, now: now).plainText, "1: —")
    }

    func testStaleLabelIsDimmed() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 95)], isStale: true)
        let label = Formatting.barLabel(account: account, index: 4, cached: cached, now: now)
        XCTAssertTrue(label.dimmed)
        XCTAssertEqual(label.plainText, "4: 5h 5%")
    }

    func testBarLabelNeverCarriesTokenPlanEmailOrNickname() {
        // ISC-116: the label is built from the account's number and the window list only.
        let account = UIFixtures.account("me@example.com", nickname: "Work")
        let cached = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 10)], planLabel: "max")
        let label = Formatting.barLabel(account: account, index: 1, cached: cached, now: now)
        XCTAssertFalse(label.plainText.contains(account.id.uuidString))
        XCTAssertFalse(label.plainText.lowercased().contains("max"))
        XCTAssertFalse(label.plainText.contains("Bearer"))
        XCTAssertFalse(label.plainText.contains("me@example.com"))
        XCTAssertFalse(label.plainText.contains("Work"))
    }

    // MARK: Accessibility

    func testAccessibilityLabelShape() {
        let window = UIFixtures.window("7d", label: "Weekly", used: 41.6)
        XCTAssertEqual(
            Formatting.accessibilityLabel(providerName: "Claude", displayName: "Work", window: window),
            "Claude Work 7-day limit 58 percent left"
        )
        let scoped = UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 100)
        XCTAssertEqual(
            Formatting.accessibilityLabel(providerName: "Claude", displayName: "me@example.com", window: scoped),
            "Claude me@example.com 7-day Fable 0 percent left"
        )
    }
}
