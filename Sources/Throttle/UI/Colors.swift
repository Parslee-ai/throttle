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
    /// The track of an empty bar: the whole bar reads red.
    case criticalTrack
    case divider
    /// The quietest text: reset timestamps, "No reset pending", data age.
    case quietText

    /// `0xRRGGBB` under a dark appearance.
    var dark: UInt32 {
        switch self {
        case .green: return 0x25B07F
        case .yellow: return 0xE8B931
        case .red: return 0xEF4444
        case .windowBackground: return 0x191817
        case .track: return 0x2E2D2B
        case .criticalTrack: return 0x7A2B2A
        case .divider: return 0x2A2927
        case .quietText: return 0x7F7E7C
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
        case .criticalTrack: return 0xDF7774
        case .divider: return 0xE7E6E3
        case .quietText: return 0x737270
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

/// A part of the interface that takes its color from a usage band.
enum BandedPart: CaseIterable, Hashable, Sendable {
    /// The percentage in a popup column.
    case percentText
    /// The filled part of a bar.
    case barFill
    /// The unfilled part of a bar.
    case barTrack
    /// A window's segment in the menu bar label.
    case barSegment
}

/// How one banded part is drawn: a tone and an opacity.
struct BandInk: Hashable, Sendable {
    enum Tone: Hashable, Sendable {
        case green
        case yellow
        case red
        /// The track of an empty bar (`Swatch.criticalTrack`).
        case criticalTrack
        /// The neutral track (`Swatch.track`).
        case track
        /// Dimmed text: the secondary label color.
        case muted
    }

    let tone: Tone
    let opacity: Double

    /// True when the part reads red.
    var isRed: Bool { tone == .red || tone == .criticalTrack }
}

/// Every color the detail window and the menu bar draw with. Text uses the
/// semantic `.primary` / `.secondary` styles, plus `quietText` for the
/// quietest lines.
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
    static let criticalTrack = Swatch.criticalTrack.color
    static let divider = Swatch.divider.color
    static let quietText = Swatch.quietText.color

    /// How much a stale or failed reading fades what it is allowed to fade.
    static let dimmedOpacity = 0.5

    /// The one decision for how a banded part is drawn, given its band and
    /// whether the reading is dimmed (stale, failed, rate limited, or signed
    /// out).
    ///
    /// Red is never dimmed, faded, or dropped: a critical percentage, an
    /// empty bar's track, and a critical bar segment are full-strength red
    /// whatever else is dimmed, so "0%" is never shown in any other color.
    /// Everything else fades with the reading.
    static func ink(for part: BandedPart, band: UsageBand, dimmed: Bool) -> BandInk {
        if band == .critical {
            return BandInk(tone: part == .barTrack ? .criticalTrack : .red, opacity: 1)
        }
        let fade = dimmed ? dimmedOpacity : 1
        switch part {
        case .percentText:
            return dimmed ? BandInk(tone: .muted, opacity: fade) : BandInk(tone: tone(for: band), opacity: 1)
        case .barSegment:
            // The whole label is already drawn secondary when dimmed.
            return dimmed ? BandInk(tone: .muted, opacity: 1) : BandInk(tone: tone(for: band), opacity: 1)
        case .barFill:
            return BandInk(tone: tone(for: band), opacity: fade)
        case .barTrack:
            return BandInk(tone: .track, opacity: fade)
        }
    }

    /// The SwiftUI color for an ink.
    static func color(for ink: BandInk) -> Color {
        let base: Color
        switch ink.tone {
        case .green: base = green
        case .yellow: base = yellow
        case .red: base = red
        case .criticalTrack: base = criticalTrack
        case .track: base = track
        case .muted: base = .secondary
        }
        return ink.opacity < 1 ? base.opacity(ink.opacity) : base
    }

    /// The AppKit color for an ink, for drawing outside SwiftUI (the menu bar
    /// image). Dynamic: it resolves in the appearance it is drawn in.
    static func nsColor(for ink: BandInk) -> NSColor {
        let base: NSColor
        switch ink.tone {
        case .green: base = Swatch.green.nsColor
        case .yellow: base = Swatch.yellow.nsColor
        case .red: base = Swatch.red.nsColor
        case .criticalTrack: base = Swatch.criticalTrack.nsColor
        case .track: base = Swatch.track.nsColor
        case .muted: base = .secondaryLabelColor
        }
        return ink.opacity < 1 ? base.withAlphaComponent(ink.opacity) : base
    }

    /// The color of a banded part: `ink` then `color(for:)`.
    static func color(for part: BandedPart, band: UsageBand, dimmed: Bool) -> Color {
        color(for: ink(for: part, band: band, dimmed: dimmed))
    }

    private static func tone(for band: UsageBand) -> BandInk.Tone {
        switch band {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}
