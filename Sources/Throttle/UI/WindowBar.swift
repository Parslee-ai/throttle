import SwiftUI

/// One labelled progress bar for one usage window (ISC-118, 119, 129).
struct WindowBar: View {
    let window: UsageWindow
    let providerName: String
    let email: String
    let showRemaining: Bool
    let dimmed: Bool
    let now: Date

    private var band: UsageBand { Colors.band(for: window.usedPercent) }
    private var usedPercent: Int { Formatting.displayPercent(used: window.usedPercent, showRemaining: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Formatting.percentText(used: window.usedPercent, showRemaining: showRemaining))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(percentStyle)
            }
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .progressViewStyle(.linear)
                .tint(Colors.barTint(for: band))
            if let reset = Formatting.resetPhrase(resetsAt: window.resetsAt, now: now) {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(providerName: providerName, email: email, window: window))
    }

    /// `"Claude someone@example.com Weekly 42 percent used"` (ISC-129).
    nonisolated static func accessibilityLabel(providerName: String, email: String, window: UsageWindow) -> String {
        let percent = Formatting.displayPercent(used: window.usedPercent, showRemaining: false)
        return "\(providerName) \(email) \(window.label) \(percent) percent used"
    }

    private var percentStyle: AnyShapeStyle {
        if dimmed { return AnyShapeStyle(.secondary) }
        if let color = Colors.color(for: band) { return AnyShapeStyle(color) }
        return AnyShapeStyle(.primary)
    }
}
