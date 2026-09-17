import SwiftUI

/// The three usage bands the bar and the detail window share (ISC-110, ISC-119).
enum UsageBand: Hashable, Sendable {
    /// Below 70 % used: the default label color.
    case normal
    /// 70–89 % used: orange.
    case warning
    /// 90 % and above: red.
    case critical
}

enum Colors {
    /// Band thresholds. Both are inclusive lower bounds.
    static let warningThreshold: Double = 70
    static let criticalThreshold: Double = 90

    /// The band for a percentage of the window *used*. Callers that show the
    /// remaining percentage must still pass the used value, so the colors mean
    /// the same thing in both modes.
    static func band(for usedPercent: Double) -> UsageBand {
        if usedPercent >= criticalThreshold { return .critical }
        if usedPercent >= warningThreshold { return .warning }
        return .normal
    }

    /// The tint for a band. `nil` means "leave the default label color alone",
    /// which is how the normal band stays legible in both appearances.
    static func color(for band: UsageBand) -> Color? {
        switch band {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// The progress-bar fill for a band. The normal band uses the accent color
    /// so an unremarkable bar still reads as a bar.
    static func barTint(for band: UsageBand) -> Color {
        color(for: band) ?? .accentColor
    }

    /// The worst band across a set of windows, used when the whole label has
    /// to carry one color.
    static func worstBand(of windows: [UsageWindow]) -> UsageBand {
        var worst = UsageBand.normal
        for window in windows {
            switch band(for: window.usedPercent) {
            case .critical: return .critical
            case .warning: worst = .warning
            case .normal: break
            }
        }
        return worst
    }
}
