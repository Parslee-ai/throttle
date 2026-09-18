import XCTest
@testable import Throttle

final class FormattingTests: XCTestCase {
    private let now = UIFixtures.now

    // MARK: Percentages

    func testPercentTextUsedAndRemaining() {
        XCTAssertEqual(Formatting.percentText(used: 42.4, showRemaining: false), "42%")
        XCTAssertEqual(Formatting.percentText(used: 42.4, showRemaining: true), "58%")
        XCTAssertEqual(Formatting.percentText(used: 140, showRemaining: false), "100%")
        XCTAssertEqual(Formatting.percentText(used: -5, showRemaining: true), "100%")
    }

    // MARK: Reset phrasing

    func testResetUnderADayUsesHoursAndMinutes() {
        let resetsAt = now.addingTimeInterval(2 * 3600 + 14 * 60)
        XCTAssertEqual(Formatting.resetPhrase(resetsAt: resetsAt, now: now), "resets in 2h 14m")
    }

    func testResetOverADayUsesWeekdayAndClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let resetsAt = now.addingTimeInterval(30 * 3600)
        let phrase = Formatting.resetPhrase(resetsAt: resetsAt, now: now, calendar: calendar)
        XCTAssertNotNil(phrase)
        XCTAssertTrue(phrase!.hasPrefix("resets "), phrase!)
        XCTAssertFalse(phrase!.contains(" in "), phrase!)
        let expectedFormatter = DateFormatter()
        expectedFormatter.calendar = calendar
        expectedFormatter.timeZone = calendar.timeZone
        expectedFormatter.dateFormat = "EEE HH:mm"
        XCTAssertEqual(phrase, "resets " + expectedFormatter.string(from: resetsAt))
    }

    func testResetNilAndPast() {
        XCTAssertNil(Formatting.resetPhrase(resetsAt: nil, now: now))
        XCTAssertEqual(Formatting.resetPhrase(resetsAt: now.addingTimeInterval(-5), now: now), "resets now")
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

    // MARK: Truncation

    func testMiddleTruncationKeepsBothEnds() {
        let email = "someone.with.a.very.long.name@example-company.com"
        let truncated = Formatting.middleTruncate(email)
        XCTAssertEqual(truncated.count, 28)
        XCTAssertTrue(truncated.contains("…"))
        XCTAssertTrue(truncated.hasPrefix("someone"))
        XCTAssertTrue(truncated.hasSuffix(".com"))
        XCTAssertEqual(Formatting.middleTruncate("short@x.io"), "short@x.io")
    }

    // MARK: Bar label

    func testBarLabelComposesGlyphEmailAndWindowsInOrder() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 42),
            UIFixtures.window("7d", label: "Weekly", used: 71),
            UIFixtures.window("scoped:Fable", label: "Fable", used: 93),
        ])
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: false, now: now)
        XCTAssertEqual(label.symbolName, Provider.anthropic.symbolName)
        XCTAssertEqual(label.email, "me@example.com")
        XCTAssertEqual(label.segments.map(\.text), ["5h 42%", "Weekly 71%", "Fable 93%"])
        XCTAssertEqual(label.segments.map(\.band), [.normal, .warning, .critical])
        XCTAssertFalse(label.dimmed)
        XCTAssertLessThanOrEqual(label.plainText.count, Formatting.barCharacterBudget)
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
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: false, now: now)
        XCTAssertEqual(label.segments.map(\.text), ["5h 20%", "Weekly 30%"])
        XCTAssertFalse(label.plainText.contains("Spark"))
    }

    func testBarLabelShowsRemainingWhenAsked() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 42)])
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: true, now: now)
        XCTAssertEqual(label.segments.map(\.text), ["5h 58%"])
        // The band still follows the used percentage.
        XCTAssertEqual(label.segments.first?.band, .normal)
    }

    func testBarLabelTruncatesEmailThenDropsWindowLabels() {
        let account = UIFixtures.account("someone.with.a.very.long.name@example-company.com")
        let cached = UIFixtures.cached(for: account, windows: [
            UIFixtures.window("5h", label: "5h", used: 42),
            UIFixtures.window("7d", label: "Weekly", used: 71),
            UIFixtures.window("scoped:Fable", label: "Fable", used: 93),
            UIFixtures.window("scoped:Opus", label: "Opus", used: 12),
        ])
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: false, now: now)
        XCTAssertLessThanOrEqual(label.email.count, Formatting.emailBudget)
        XCTAssertLessThanOrEqual(label.plainText.count, Formatting.barCharacterBudget, label.plainText)
        XCTAssertEqual(label.segments.map(\.text), ["42%", "71%", "93%", "12%"], "labels drop before the email shrinks past its budget")
        XCTAssertFalse(label.plainText.contains("\n"))
    }

    func testBarLabelStateMarkers() {
        let account = UIFixtures.account("me@example.com", provider: .openai)
        let needsLogin = UIFixtures.cached(for: account, windows: [], state: .needsLogin)
        XCTAssertEqual(Formatting.barLabel(account: account, cached: needsLogin, showRemaining: false, now: now).segments.map(\.text), ["⚠︎ login"])

        let until = now.addingTimeInterval(1800)
        let limited = UIFixtures.cached(for: account, windows: [], state: .rateLimited(until: until))
        let text = Formatting.barLabel(account: account, cached: limited, showRemaining: false, now: now).segments.first?.text
        XCTAssertEqual(text, "⏳ retry \(Formatting.clockTime(until))")

        let forbidden = UIFixtures.cached(for: account, windows: [], state: .forbidden("OAuth authentication is currently not allowed for this organization."))
        let forbiddenLabel = Formatting.barLabel(account: account, cached: forbidden, showRemaining: false, now: now)
        XCTAssertEqual(forbiddenLabel.segments.map(\.text), ["🔒 org policy"])
        XCTAssertEqual(forbiddenLabel.segments.first?.band, .warning)
        XCTAssertFalse(forbiddenLabel.dimmed)
        XCTAssertFalse(forbiddenLabel.plainText.contains("organization"), "the provider's message stays out of the bar")

        let empty = Formatting.barLabel(account: account, cached: nil, showRemaining: false, now: now)
        XCTAssertTrue(empty.dimmed)
    }

    func testStaleLabelIsDimmedAndUncoloured() {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 95)], isStale: true)
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: false, now: now)
        XCTAssertTrue(label.dimmed)
        XCTAssertEqual(label.segments.map(\.band), [.normal])
    }

    func testBarLabelNeverCarriesTokenOrPlan() {
        // ISC-116: the label is built from the account and the window list only.
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 10)])
        let label = Formatting.barLabel(account: account, cached: cached, showRemaining: false, now: now)
        XCTAssertFalse(label.plainText.contains(account.id.uuidString))
        XCTAssertFalse(label.plainText.lowercased().contains("max"))
        XCTAssertFalse(label.plainText.contains("Bearer"))
    }

    func testAccessibilityLabelShape() {
        let window = UIFixtures.window("7d", label: "Weekly", used: 41.6)
        XCTAssertEqual(
            WindowBar.accessibilityLabel(providerName: "Claude", email: "me@example.com", window: window),
            "Claude me@example.com Weekly 42 percent used"
        )
    }
}
