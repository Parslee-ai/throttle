import SwiftUI

/// The question asked before a banked reset is spent: which account, how many
/// resets it holds, that it cannot be undone, and how much of each window is
/// left right now, so spending one while a window still has room is a visible
/// choice.
///
/// Drawn as a `ConfirmationCard` on a panel modal, not a SwiftUI `alert`.
/// On macOS an alert makes its first non-cancel button the Return key's
/// target, which here would be "Use reset", and it is a window of its own,
/// which closes the detail panel when clicked. The card makes **Cancel** the
/// default button (Return) and the cancel action (Escape) and gives it the
/// initial focus, so no key pressed alone ever spends a reset. "Use reset"
/// has no shortcut: it takes a click, or Tab to it and Space.
struct ResetConfirmation: View {
    let displayName: String
    let count: Int
    /// The row's primary windows, in the row's order.
    let windows: [UsageWindow]
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    static func title(count: Int, displayName: String) -> String {
        "Use 1 of \(count) \(count == 1 ? "reset" : "resets") for \(displayName)?"
    }

    static let warning = "A reset can't be undone."

    /// `5-hour limit: 30% left`, one line per window.
    static func windowLines(_ windows: [UsageWindow]) -> [String] {
        windows.map { "\(Formatting.longLabel(for: $0)): \(Formatting.remainingPercent(used: $0.usedPercent))% left" }
    }

    var body: some View {
        ConfirmationCard(
            title: Self.title(count: count, displayName: displayName),
            confirmTitle: "Use reset",
            onConfirm: onConfirm,
            onCancel: onCancel
        ) {
            Text(Self.warning)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Left right now")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ForEach(Self.windowLines(windows), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13).monospacedDigit())
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
