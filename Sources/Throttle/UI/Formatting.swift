import Foundation

/// One run of text in the menu bar label with the band that colors it.
struct BarSegment: Hashable, Sendable {
    let text: String
    let band: UsageBand
}

/// What the menu bar draws for one account (ISC-107). Built by
/// `Formatting.barLabel` from cached data only; nothing here can fetch.
struct BarLabel: Hashable, Sendable {
    /// SF Symbol name for the provider glyph.
    let symbolName: String
    /// The account's 1-based position in the display order, the same number
    /// the detail window shows beside the account.
    let index: Int
    /// Window percentages such as `5h 100%`, or a single state marker such
    /// as `⚠︎ login`.
    let segments: [BarSegment]
    /// True when windows were left out to keep the label short; it then ends
    /// with `Formatting.overflowMarker`.
    let isTruncated: Bool
    /// True when the numbers are stale: the label dims and drops its colors.
    let dimmed: Bool

    /// `1: `, drawn in the default label color.
    var prefix: String { "\(index): " }

    /// The label as one line, for width budgeting and tests.
    var plainText: String {
        prefix
            + segments.map(\.text).joined(separator: Formatting.segmentSeparator)
            + (isTruncated ? Formatting.overflowMarker : "")
    }
}

/// The reset line under a bar, split so the view can style the relative part
/// and the timestamp differently.
struct ResetText: Hashable, Sendable {
    /// `in 5 days`, `resetting now`, or `No reset pending`.
    let relative: String
    /// `09/27, 12:59` in the user's locale, or `nil` when there is none.
    let stamp: String?
    /// False when the provider reported no reset time.
    let isScheduled: Bool

    /// `in 5 days · 09/27, 12:59`.
    var line: String {
        guard let stamp else { return relative }
        return relative + Formatting.stampSeparator + stamp
    }
}

/// Pure text helpers shared by the bar and the detail window. No view code,
/// so every rule here is unit-testable.
enum Formatting {
    /// Longest the bar text may run before windows are dropped (ISC-115).
    static let barCharacterBudget = 40
    /// Separator between window segments in the bar.
    static let segmentSeparator = " / "
    /// Ends a bar label that had to leave windows out.
    static let overflowMarker = " …"
    /// Between the relative reset time and its timestamp.
    static let stampSeparator = " · "

    // MARK: Percentages

    /// The percentage shown for a window, everywhere: what is left, clamped
    /// to 0...100 and rounded. The band color derives from this same number.
    static func remainingPercent(used: Double) -> Int {
        let clamped = used.isNaN ? 0 : min(100, max(0, used))
        return Int((100 - clamped).rounded())
    }

    /// `"79%"`, the percentage left.
    static func percentText(used: Double) -> String {
        "\(remainingPercent(used: used))%"
    }

    // MARK: Window labels

    /// `5-hour`, `7-day`, `3-hour`, `2-day`: the window length as an
    /// adjective, derived from the reported length, never from a lane name.
    static func lengthPhrase(forDurationSeconds seconds: Int) -> String {
        if seconds >= 86_400, seconds % 86_400 == 0 {
            return "\(seconds / 86_400)-day"
        }
        let hours = max(1, Int((Double(seconds) / 3600.0).rounded()))
        return "\(hours)-hour"
    }

    /// The popup title for a window: `5-hour limit`, `7-day limit`, or, for a
    /// window that counts one model, the length plus the model name the
    /// payload reported, such as `7-day Fable`. Lanes keep their own label.
    static func longLabel(for window: UsageWindow) -> String {
        if window.isLane { return window.label }
        let length = lengthPhrase(forDurationSeconds: window.durationSeconds)
        if window.isModelScoped { return "\(length) \(window.label)" }
        return "\(length) limit"
    }

    /// The menu bar tag for a window: `5h`, `WK`, `3h`, `2d`, or two letters
    /// from the model name for a model-scoped window.
    static func shortLabel(for window: UsageWindow) -> String {
        if window.isModelScoped { return modelTag(window.label) }
        switch window.durationSeconds {
        case 18_000: return "5h"
        case 604_800: return "WK"
        default: return UsageWindow.label(forDurationSeconds: window.durationSeconds)
        }
    }

    /// Two uppercase letters for a model name: its first letter and the first
    /// consonant after it (`Fable` → `FB`, `Opus` → `OP`, `Sonnet` → `SN`).
    /// Falls back to the first two letters when no consonant follows.
    static func modelTag(_ name: String) -> String {
        let letters = Array(name.filter(\.isLetter))
        guard let first = letters.first else {
            let fallback = String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
            return fallback.isEmpty ? "?" : fallback
        }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        if let consonant = letters.dropFirst().first(where: { !vowels.contains(Character($0.lowercased())) }) {
            return (String(first) + String(consonant)).uppercased()
        }
        return String(letters.prefix(2)).uppercased()
    }

    // MARK: Window order

    /// The windows to draw for a cached status: the current reading, or the
    /// last good one while a failure is showing.
    static func windows(of cached: CachedStatus?) -> [UsageWindow] {
        guard let cached else { return [] }
        return cached.status.windows.isEmpty ? (cached.lastGoodWindows ?? []) : cached.status.windows
    }

    /// Popup column order: model-scoped windows, then the session (shortest)
    /// window, then the weekly window, then anything else. Lanes excluded.
    static func popupOrder(_ windows: [UsageWindow]) -> [UsageWindow] {
        let groups = grouped(windows)
        return groups.scoped + groups.session + groups.weekly + groups.others
    }

    /// Menu bar order: session, weekly, anything else, then model-scoped.
    /// Lanes never reach the bar (ISC-73).
    static func barOrder(_ windows: [UsageWindow]) -> [UsageWindow] {
        let groups = grouped(windows)
        return groups.session + groups.weekly + groups.others + groups.scoped
    }

    private static func grouped(_ windows: [UsageWindow]) -> (
        scoped: [UsageWindow], session: [UsageWindow], weekly: [UsageWindow], others: [UsageWindow]
    ) {
        let primary = windows.filter { !$0.isLane }
        let scoped = primary.filter(\.isModelScoped)
        var rest = primary.filter { !$0.isModelScoped }
        var session: [UsageWindow] = []
        var weekly: [UsageWindow] = []
        if let shortest = rest.indices.min(by: { rest[$0].durationSeconds < rest[$1].durationSeconds }) {
            session.append(rest.remove(at: shortest))
        }
        if let week = rest.firstIndex(where: { $0.durationSeconds == 604_800 }) {
            weekly.append(rest.remove(at: week))
        }
        return (scoped, session, weekly, rest)
    }

    // MARK: Times

    /// The reset line for a window (ISC-118): the largest whole unit to go,
    /// then a local month/day and 24-hour stamp.
    static func resetText(
        resetsAt: Date?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ResetText {
        guard let resetsAt else {
            return ResetText(relative: "No reset pending", stamp: nil, isScheduled: false)
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 {
            return ResetText(relative: "resetting now", stamp: nil, isScheduled: true)
        }
        return ResetText(
            relative: relativeReset(remaining),
            stamp: resetStamp(resetsAt, calendar: calendar, locale: locale),
            isScheduled: true
        )
    }

    /// `in 5 days`, `in 1 hour`, `in 12 minutes`: the largest whole unit only.
    /// Minutes round up, so a reset 30 seconds away says `in 1 minute`.
    static func relativeReset(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "resetting now" }
        if interval >= 86_400 {
            let days = Int(interval / 86_400)
            return days == 1 ? "in 1 day" : "in \(days) days"
        }
        if interval >= 3600 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "in 1 hour" : "in \(hours) hours"
        }
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        return minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
    }

    /// Month, day, and 24-hour time in the user's locale; `09/27, 12:59` in
    /// en_US.
    static func resetStamp(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMddHHmm", options: 0, locale: locale) ?? "MM/dd, HH:mm"
        return formatter.string(from: date)
    }

    /// `2h 14m`, `45m`, `3d 2h`. Minutes are rounded up so a window that
    /// resets in 90 seconds says `2m`, never `1m` or `0m`.
    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((max(0, interval) / 60).rounded(.up))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// `HH:mm`, for `⏳ retry 14:05` and settings text.
    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        formatted(date, "HH:mm", calendar: calendar)
    }

    /// `HH:mm:ss`, for the footer's last-updated stamp (ISC-125).
    static func clockTimeWithSeconds(_ date: Date, calendar: Calendar = .current) -> String {
        formatted(date, "HH:mm:ss", calendar: calendar)
    }

    /// `updated 12m ago` (ISC-104).
    static func agePhrase(since date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "updated just now" }
        return "updated \(durationText(age)) ago"
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Account text

    /// The plan under the account name: `max` → `Max`, `pro_20x` → `Pro 20x`.
    /// `nil` when there is no plan to show.
    static func planText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard let first = words.first else { return nil }
        return first.uppercased() + words.dropFirst()
    }

    /// `"Claude work 7-day limit 58 percent left"` (ISC-129).
    static func accessibilityLabel(providerName: String, displayName: String, window: UsageWindow) -> String {
        "\(providerName) \(displayName) \(longLabel(for: window)) \(remainingPercent(used: window.usedPercent)) percent left"
    }

    // MARK: Bar label

    /// The bar label for one account (ISC-107, 110, 111, 115, 116):
    /// `1: 5h 100% / WK 89% / FB 79%`.
    ///
    /// Only the glyph, the account's number, and window percentages are ever
    /// emitted. The email, the nickname, the account id, the plan, and the
    /// credential never reach this function's output.
    ///
    /// Width rule (ISC-115): when every window would push the text past
    /// `barCharacterBudget`, the label keeps as many whole windows as fit and
    /// ends with `overflowMarker`. The line never wraps.
    static func barLabel(account: Account, index: Int, cached: CachedStatus?, now: Date) -> BarLabel {
        let symbol = account.provider.symbolName

        func marker(_ text: String, band: UsageBand, dimmed: Bool) -> BarLabel {
            BarLabel(
                symbolName: symbol,
                index: index,
                segments: [BarSegment(text: text, band: band)],
                isTruncated: false,
                dimmed: dimmed
            )
        }

        guard let cached else {
            return marker("…", band: .normal, dimmed: true)
        }

        switch cached.status.state {
        case .needsLogin:
            return marker("⚠︎ login", band: .warning, dimmed: false)
        case .rateLimited(let until):
            return marker("⏳ retry \(clockTime(until))", band: .warning, dimmed: false)
        case .forbidden:
            return marker("🔒 sign in again", band: .warning, dimmed: false)
        case .ok, .error:
            break
        }

        let windows = barOrder(windows(of: cached))
        let dimmed = cached.isStale
        if windows.isEmpty {
            if case .error = cached.status.state {
                return marker("⚠︎ error", band: .normal, dimmed: true)
            }
            return marker("—", band: .normal, dimmed: true)
        }

        let segments = windows.map { window in
            BarSegment(
                text: "\(shortLabel(for: window)) \(percentText(used: window.usedPercent))",
                band: Colors.band(for: window)
            )
        }

        let full = BarLabel(symbolName: symbol, index: index, segments: segments, isTruncated: false, dimmed: dimmed)
        if full.plainText.count <= barCharacterBudget { return full }

        var kept = segments
        while kept.count > 1 {
            kept.removeLast()
            let candidate = BarLabel(symbolName: symbol, index: index, segments: kept, isTruncated: true, dimmed: dimmed)
            if candidate.plainText.count <= barCharacterBudget { return candidate }
        }
        return BarLabel(symbolName: symbol, index: index, segments: kept, isTruncated: true, dimmed: dimmed)
    }

    /// The bar text with no accounts (ISC-112).
    static let emptyBarText = "Throttle · add account"
}
