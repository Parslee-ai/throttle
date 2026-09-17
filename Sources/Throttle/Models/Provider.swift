import Foundation

/// The subscription providers Throttle can read usage from.
///
/// Adding a third provider means adding a case here and one adapter under
/// `Providers/`. Nothing in `UI/` may branch on a specific case.
enum Provider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai

    /// The product name shown to the user, never the vendor name.
    var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "Codex"
        }
    }

    /// SF Symbol used as the provider glyph in the menu bar and detail rows.
    var symbolName: String {
        switch self {
        case .anthropic: return "sparkles"
        case .openai: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Whether the provider's hosted login page can show the code for the user
    /// to paste, as a fallback to the loopback redirect (ISC-59).
    var supportsManualCode: Bool {
        switch self {
        case .anthropic: return true
        case .openai: return false
        }
    }

    /// The "Add account" menu item for the paste-the-code login, or `nil` when
    /// the provider has no such mode.
    var manualCodeMenuTitle: String? {
        supportsManualCode ? "Paste code instead…" : nil
    }

    /// The name of the CLI tool whose login Throttle can import for this
    /// provider, or `nil` when there is none.
    var importSourceName: String? {
        switch self {
        case .anthropic: return "Claude Code"
        case .openai: return "Codex CLI"
        }
    }
}
