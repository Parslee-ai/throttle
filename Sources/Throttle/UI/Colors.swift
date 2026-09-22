import AppKit
import SwiftUI

/// The three usage bands the bar and the detail window share (ISC-110, ISC-119).
enum UsageBand: Hashable, Sendable {
    /// 21 % or more left: green.
    case normal
    /// 1–20 % left: yellow.
    case warning
    /// Nothing left: red.
    case critical
}

/// One named color with its dark-appearance and light-appearance values.
enum Swatch: CaseIterable, Sendable {
    case green
    case yellow
    case red
    case windowBackground
    case track
    case divider

    /// `0xRRGGBB` under a dark appearance.
    var dark: UInt32 {
        switch self {
        case .green: return 0x25B07F
        case .yellow: return 0xE8B931
        case .red: return 0xEF4444
        case .windowBackground: return 0x191817
        case .track: return 0x2E2D2B
        case .divider: return 0x2A2927
        }
    }

    /// `0xRRGGBB` under a light appearance.
    var light: UInt32 {
        switch self {
        case .green: return 0x1C9468
        case .yellow: return 0xB98A00
        case .red: return 0xD0312D
        case .windowBackground: return 0xFAFAF9
        case .track: return 0xE4E3E0
        case .divider: return 0xE7E6E3
        }
    }

    /// A dynamic color: AppKit asks it for a value each time it draws, with
    /// the appearance of the view it is drawn in, so it follows the system
    /// setting without anyone forcing an appearance.
    var nsColor: NSColor {
        let dark = dark
        let light = light
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return Self.srgb(isDark ? dark : light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Every color the detail window and the menu bar draw with. Text uses the
/// semantic `.primary` / `.secondary` / `.tertiary` styles instead.
enum Colors {
    /// Lowest remaining percentage, inclusive, that still reads green.
    static let normalFloor = 21

    /// The band for a displayed remaining percentage.
    ///
    /// This is the one band rule. It takes the same rounded integer the text
    /// shows, so "0%" and red are the same event and can never disagree.
    static func band(forRemaining remaining: Int) -> UsageBand {
        if remaining <= 0 { return .critical }
        if remaining < normalFloor { return .warning }
        return .normal
    }

    /// The band for a window, through the percentage the UI displays for it.
    static func band(for window: UsageWindow) -> UsageBand {
        band(forRemaining: Formatting.remainingPercent(used: window.usedPercent))
    }

    static let green = Swatch.green.color
    static let yellow = Swatch.yellow.color
    static let red = Swatch.red.color
    static let windowBackground = Swatch.windowBackground.color
    static let track = Swatch.track.color
    static let divider = Swatch.divider.color

    /// The color of a band's bar fill, percentage text, and bar segment.
    static func color(for band: UsageBand) -> Color {
        switch band {
        case .normal: return green
        case .warning: return yellow
        case .critical: return red
        }
    }

    /// The unfilled part of a bar. An empty bar has no fill to carry the red,
    /// so its track turns red instead.
    static func track(for band: UsageBand) -> Color {
        band == .critical ? red.opacity(0.35) : track
    }
}
