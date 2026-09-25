import AppKit
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
                    // The digits roll to a new reading in step with the bar.
                    .contentTransition(.numericText(value: Double(remaining)))
                    .animation(UsageBar.fillAnimation, value: remaining)
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
///
/// A new reading slides the fill from its old width to the new one (after a
/// reset, from what was left up to the fresh reading) rather than jumping.
/// The fill is always in the hierarchy, invisible at zero, so a bar coming
/// back from empty slides too instead of popping in.
struct UsageBar: View {
    /// Remaining fraction, 0...1.
    let fraction: Double
    let band: UsageBand
    let dimmed: Bool
    let width: CGFloat

    /// How a changed reading moves the fill, the percentage, and the color.
    static let fillAnimation = Animation.easeInOut(duration: fillDuration)
    static let fillDuration: TimeInterval = 0.8

    /// Width of the fill for a remaining fraction.
    static func filledWidth(fraction: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        let filled = Self.filledWidth(fraction: fraction, width: width)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Colors.color(for: .barTrack, band: band, dimmed: dimmed))
            Capsule()
                .fill(Colors.color(for: .barFill, band: band, dimmed: dimmed))
                .frame(width: max(filled, PopupMetrics.barHeight))
                .opacity(filled > 0 ? 1 : 0)
        }
        .frame(width: width, height: PopupMetrics.barHeight)
        .animation(Self.fillAnimation, value: fraction)
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
/// many limit resets it has banked. It keeps the `WindowBar` rhythm of three
/// lines: the title, then the count with the **Use reset** button at its
/// trailing edge, then a status line that appears only while a reset runs
/// ("Resetting…") or while its message shows. At rest the column is exactly
/// as tall as the title and count alone, so the button never makes a row
/// taller, and everything stays inside the column's fixed width, so the row
/// never gets wider.
struct ResetCreditsColumn: View {
    let count: Int
    let dimmed: Bool
    /// The row's name, for the button's spoken label.
    var displayName: String = ""
    /// A reset for this account is running: the button gives way to a
    /// spinner on the status line.
    var isResetting: Bool = false
    var notice: ResetNotice?
    /// How wide the reset message may run, from the column's leading edge.
    /// The row passes the free width to the end of the column line, so a
    /// message uses the empty slots to the right (up to the actions button)
    /// instead of wrapping inside the column. The column itself keeps its
    /// fixed width; the message overflows to the right.
    var noticeSpan: CGFloat = PopupMetrics.columnWidth
    /// Asks for the confirmation; never spends anything by itself.
    var onUse: @MainActor () -> Void = {}
    var onDismissNotice: @MainActor () -> Void = {}

    /// Lines a reset message may take before it truncates; the full text is
    /// in its tooltip.
    static let noticeLineLimit = 2
    /// The message line's icon and close button, with their spacing.
    static let noticeIconWidth: CGFloat = 12
    static let noticeCloseWidth: CGFloat = 14
    static let noticeSpacing: CGFloat = 6

    /// The width the message's text gets inside a span.
    static func noticeTextWidth(span: CGFloat) -> CGFloat {
        span - noticeIconWidth - noticeCloseWidth - 2 * noticeSpacing
    }

    /// The message's font, as AppKit measures it.
    static let noticeFontSize: CGFloat = 12

    /// Whether `text` fits on one line of a notice drawn across `span`. A
    /// message that does not is drawn on a line of its own under the row's
    /// columns instead, so no message is ever cut or wraps inside a column.
    /// A couple of points are held back so AppKit's measure and SwiftUI's
    /// layout cannot disagree at the edge.
    static func noticeFitsOnOneLine(_ text: String, span: CGFloat) -> Bool {
        let font = NSFont.systemFont(ofSize: noticeFontSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width.rounded(.up) + 2 <= noticeTextWidth(span: span)
    }

    /// Why a reset cannot be started now, or `nil` when it can. The row's
    /// menus use the same rule as the button.
    static func disabledReason(count: Int, dimmed: Bool) -> String? {
        if count <= 0 { return "No resets available" }
        if dimmed { return "Refresh this account first" }
        return nil
    }

    private var disabledReason: String? { Self.disabledReason(count: count, dimmed: dimmed) }
    private var fade: Double { dimmed ? Colors.dimmedOpacity : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual resets")
                    .font(.system(size: 13))
                    .foregroundStyle(PopupStyle.columnTitle)
                    .lineLimit(1)
                    .opacity(fade)
                    .accessibilityHidden(true)
                (Text("\(count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                 + Text("  available")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary))
                    .lineLimit(1)
                    .opacity(fade)
                    .accessibilityLabel("Manual resets, \(count) available")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // An overlay, so the button never adds height to the line.
                    .overlay(alignment: .trailing) {
                        if !isResetting { useButton }
                    }
            }
            statusLine
        }
        .frame(width: PopupMetrics.columnWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.3), value: notice)
    }

    private var useButton: some View {
        Button("Use reset", action: onUse)
            .controlSize(.small)
            .disabled(disabledReason != nil)
            .help(disabledReason ?? "Spend one banked reset for this account")
            .accessibilityLabel("Use reset for \(displayName), \(count) available")
            .accessibilityHint(disabledReason ?? "Asks you to confirm first")
    }

    /// The column's third line, in the place a window's reset line takes.
    @ViewBuilder
    private var statusLine: some View {
        if isResetting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .frame(width: 14, height: 14)
                Text("Resetting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resetting \(displayName)")
            .padding(.top, 6)
        } else if let notice {
            ResetNoticeLine(notice: notice, onDismiss: onDismissNotice)
                .frame(width: max(noticeSpan, PopupMetrics.columnWidth), alignment: .leading)
                // Reported at the column's width, so the count line and its
                // button stay where they are; the message overflows right.
                .frame(width: PopupMetrics.columnWidth, alignment: .leading)
                .padding(.top, 6)
                .transition(.opacity)
        }
    }
}

/// One reset message: its icon, the text, and a close button. Drawn in the
/// resets column's status line when it fits there on one line, otherwise on a
/// line of its own under the row's columns.
struct ResetNoticeLine: View {
    let notice: ResetNotice
    var onDismiss: @MainActor () -> Void = {}

    var body: some View {
        let success = notice.kind == .success
        HStack(alignment: .top, spacing: ResetCreditsColumn.noticeSpacing) {
            Image(systemName: success ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(success ? AnyShapeStyle(Colors.green) : AnyShapeStyle(.orange))
                .frame(width: ResetCreditsColumn.noticeIconWidth)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.system(size: ResetCreditsColumn.noticeFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(ResetCreditsColumn.noticeLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(notice.text)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: ResetCreditsColumn.noticeCloseWidth, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close message")
        }
    }
}

/// Text styles shared by the detail window's views.
enum PopupStyle {
    /// Column titles: quieter than the account name, brighter than the reset
    /// line under them.
    static let columnTitle = Color.primary.opacity(0.82)
}
