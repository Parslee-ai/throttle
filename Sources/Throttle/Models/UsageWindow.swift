import Foundation

/// One rolling usage window reported by a provider, such as the 5-hour session
/// window or a weekly model-scoped window.
struct UsageWindow: Codable, Hashable, Sendable {
    /// Stable identity for the window within its account, e.g. `5h`, `7d`,
    /// `scoped:Opus`. Adapters derive this, never the UI.
    let key: String
    /// Human-readable label shown next to the percentage, e.g. `5h`, `Weekly`.
    let label: String
    /// Percentage of the window used, 0...100.
    let usedPercent: Double
    /// When the window rolls over. `nil` when the provider omits it.
    let resetsAt: Date?
    /// Length of the window in seconds, as reported by the provider.
    let durationSeconds: Int

    /// Keys with this prefix are secondary, per-model lanes (ISC-73). The
    /// detail window shows them collapsed after the primary windows; the menu
    /// bar never shows them.
    static let lanePrefix = "lane:"

    /// True for a secondary lane window.
    var isLane: Bool { key.hasPrefix(Self.lanePrefix) }

    /// Keys with this prefix belong to a window that counts one model only.
    /// Its `label` is the model name exactly as the payload reported it, so
    /// the UI can title the window without ever naming a model itself.
    static let scopedPrefix = "scoped:"

    /// True for a model-scoped window.
    var isModelScoped: Bool { key.hasPrefix(Self.scopedPrefix) }

    init(
        key: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        durationSeconds: Int
    ) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
    }

    /// Derives a display label from a window length.
    ///
    /// Adapters call this instead of hardcoding lane names, because providers
    /// have turned individual lanes on and off without warning.
    static func label(forDurationSeconds seconds: Int) -> String {
        switch seconds {
        case 18_000:
            return "5h"
        case 604_800:
            return "Weekly"
        default:
            if seconds >= 86_400, seconds % 86_400 == 0 {
                return "\(seconds / 86_400)d"
            }
            let hours = max(1, Int((Double(seconds) / 3600.0).rounded()))
            return "\(hours)h"
        }
    }
}
