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
}
