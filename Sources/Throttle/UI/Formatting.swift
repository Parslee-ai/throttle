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
    /// The email, already middle-truncated.
    let email: String
    /// Window percentages, or a single state marker such as `⚠︎ login`.
    let segments: [BarSegment]
    /// True when the numbers are stale: the label dims and drops its colors.
    let dimmed: Bool

    /// The label as one line, for width budgeting and tests.
    var plainText: String {
        ([email] + segments.map(\.text)).joined(separator: "  ")
    }
}

/// Pure text helpers shared by the bar and the detail window. No view code,
/// so every rule here is unit-testable.
enum Formatting {
    /// Longest email the bar shows before middle truncation (ISC-107).
    static let emailBudget = 28
    /// Character budget standing in for the 320 pt bar width limit (ISC-115).
    /// At the menu bar's 13 pt system font a character averages about 6.5 pt,
    /// so 48 characters plus the glyph stays inside 320 pt.
    static let barCharacterBudget = 48
    /// Separator between window segments in the bar.
    static let segmentSeparator = "  "

    // MARK: Percentages

    /// The percentage to display for a window: used by default, or remaining
    /// when the user asked for it. Clamped to 0...100 and rounded.
    static func displayPercent(used: Double, showRemaining: Bool) -> Int {
        let clamped = min(100, max(0, used))
        let value = showRemaining ? 100 - clamped : clamped
        return Int(value.rounded())
    }

    /// `"42%"`.
    static func percentText(used: Double, showRemaining: Bool) -> String {
        "\(displayPercent(used: used, showRemaining: showRemaining))%"
    }

    // MARK: Times

    /// `resets in 2h 14m` under 24 hours away, `resets Tue 09:00` beyond that,
    /// `resets now` once passed, `nil` when the provider gave no reset (ISC-118).
    static func resetPhrase(resetsAt: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "resets now" }
        if remaining < 24 * 3600 {
            return "resets in \(durationText(remaining))"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE HH:mm"
        return "resets \(formatter.string(from: resetsAt))"
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

    // MARK: Truncation

    /// Keeps the start and end of a long string with an ellipsis in the
    /// middle, so `someone.longname@example.com` still shows both the user and
    /// the domain.
    static func middleTruncate(_ text: String, max limit: Int = emailBudget) -> String {
        guard limit > 0 else { return "" }
        let characters = Array(text)
        guard characters.count > limit else { return text }
        guard limit > 1 else { return "…" }
        let keep = limit - 1
        let head = (keep + 1) / 2
        let tail = keep - head
        let prefix = String(characters[0..<head])
        let suffix = tail > 0 ? String(characters[(characters.count - tail)...]) : ""
        return prefix + "…" + suffix
    }

    // MARK: Bar label

    /// The bar label for one account (ISC-107, 110, 111, 115, 116).
    ///
    /// Only the glyph, the email, and window percentages are ever emitted. The
    /// account id, plan, and credential never reach this function.
    ///
    /// Width rule (ISC-115): the email is truncated to `emailBudget` first;
    /// when the whole line still exceeds `barCharacterBudget`, the window
    /// labels are dropped and only the percentages remain; when even that
    /// overflows, the email shrinks further. The line never wraps.
    static func barLabel(
        account: Account,
        cached: CachedStatus?,
        showRemaining: Bool,
        now: Date
    ) -> BarLabel {
        let symbol = account.provider.symbolName
        let email = middleTruncate(account.email)

        guard let cached else {
            return BarLabel(symbolName: symbol, email: email, segments: [BarSegment(text: "…", band: .normal)], dimmed: true)
        }

        switch cached.status.state {
        case .needsLogin:
            return BarLabel(symbolName: symbol, email: email, segments: [BarSegment(text: "⚠︎ login", band: .warning)], dimmed: false)
        case .rateLimited(let until):
            return BarLabel(
                symbolName: symbol,
                email: email,
                segments: [BarSegment(text: "⏳ retry \(clockTime(until))", band: .warning)],
                dimmed: false
            )
        case .ok, .error:
            break
        }

        // Secondary lanes stay in the detail window (ISC-73); the bar shows
        // only the primary windows.
        let allWindows = cached.status.windows.isEmpty ? (cached.lastGoodWindows ?? []) : cached.status.windows
        let windows = allWindows.filter { !$0.isLane }
        let dimmed = cached.isStale
        if windows.isEmpty {
            let marker: String
            if case .error = cached.status.state { marker = "⚠︎ error" } else { marker = "—" }
            return BarLabel(symbolName: symbol, email: email, segments: [BarSegment(text: marker, band: .normal)], dimmed: true)
        }

        func segments(withLabels: Bool) -> [BarSegment] {
            windows.map { window in
                let pct = percentText(used: window.usedPercent, showRemaining: showRemaining)
                let text = withLabels ? "\(window.label) \(pct)" : pct
                return BarSegment(text: text, band: dimmed ? .normal : Colors.band(for: window.usedPercent))
            }
        }

        var candidate = BarLabel(symbolName: symbol, email: email, segments: segments(withLabels: true), dimmed: dimmed)
        if candidate.plainText.count <= barCharacterBudget { return candidate }

        candidate = BarLabel(symbolName: symbol, email: email, segments: segments(withLabels: false), dimmed: dimmed)
        if candidate.plainText.count <= barCharacterBudget { return candidate }

        let overflow = candidate.plainText.count - barCharacterBudget
        let shorterEmail = middleTruncate(account.email, max: max(8, email.count - overflow))
        return BarLabel(symbolName: symbol, email: shorterEmail, segments: candidate.segments, dimmed: dimmed)
    }

    /// The bar text with no accounts (ISC-112).
    static let emptyBarText = "Throttle · add account"
}
