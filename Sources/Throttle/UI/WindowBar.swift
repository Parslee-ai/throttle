import SwiftUI

/// One usage window as a column (ISC-118, 119, 129): the window's name and
/// the percentage left on top, a bar under it, then when it resets.
///
/// The percentage, the bar fill, and the track all take their color from the
/// one band rule applied to the same rounded number the text shows, drawn
/// through `Colors.ink`. A dimmed reading fades its title, reset line, and
/// non-red parts; red stays full strength, so "0%" always reads red.
struct WindowBar: View {
    let window: UsageWindow
    let providerName: String
    let displayName: String
    let dimmed: Bool
    let now: Date

    private var remaining: Int { Formatting.remainingPercent(used: window.usedPercent) }
    private var band: UsageBand { Colors.band(forRemaining: remaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatting.longLabel(for: window))
                    .font(.system(size: 13))
                    .foregroundStyle(PopupStyle.columnTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(fade)
                Spacer(minLength: 4)
                Text("\(remaining)%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Colors.color(for: .percentText, band: band, dimmed: dimmed))
            }
            UsageBar(fraction: Double(remaining) / 100, band: band, dimmed: dimmed, width: PopupMetrics.columnWidth)
                .padding(.top, 8)
            ResetLine(reset: Formatting.resetText(resetsAt: window.resetsAt, now: now))
                .opacity(fade)
                .padding(.top, 6)
        }
        .frame(width: PopupMetrics.columnWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatting.accessibilityLabel(providerName: providerName, displayName: displayName, window: window))
    }

    /// Opacity for the parts that carry no band color.
    private var fade: Double { dimmed ? Colors.dimmedOpacity : 1 }
}

/// A thin capsule: the track, and the part of the window that is left.
struct UsageBar: View {
    /// Remaining fraction, 0...1.
    let fraction: Double
    let band: UsageBand
    let dimmed: Bool
    let width: CGFloat

    var body: some View {
        let filled = width * CGFloat(min(1, max(0, fraction)))
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Colors.color(for: .barTrack, band: band, dimmed: dimmed))
            if filled > 0 {
                Capsule()
                    .fill(Colors.color(for: .barFill, band: band, dimmed: dimmed))
                    .frame(width: max(filled, PopupMetrics.barHeight))
            }
        }
        .frame(width: width, height: PopupMetrics.barHeight)
    }
}

/// `in 5 days · 09/27, 12:59`, with the stamp one step quieter than the
/// relative time.
struct ResetLine: View {
    let reset: ResetText

    var body: some View {
        line
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var line: Text {
        guard reset.isScheduled else {
            return Text(reset.relative).foregroundStyle(Colors.quietText)
        }
        let relative = Text(reset.relative).foregroundStyle(.secondary)
        guard let stamp = reset.stamp else { return relative }
        return relative + Text(Formatting.stampSeparator + stamp).foregroundStyle(Colors.quietText)
    }
}

/// The "Manual resets" column, for an account whose provider reports how
/// many limit resets it has banked.
struct ResetCreditsColumn: View {
    let count: Int
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual resets")
                .font(.system(size: 13))
                .foregroundStyle(PopupStyle.columnTitle)
                .lineLimit(1)
            (Text("\(count)")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
             + Text("  available")
                .font(.system(size: 13))
                .foregroundStyle(.secondary))
                .lineLimit(1)
        }
        .frame(width: PopupMetrics.columnWidth, alignment: .leading)
        .opacity(dimmed ? Colors.dimmedOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Manual resets, \(count) available")
    }
}

/// Text styles shared by the detail window's views.
enum PopupStyle {
    /// Column titles: quieter than the account name, brighter than the reset
    /// line under them.
    static let columnTitle = Color.primary.opacity(0.82)
}
