import AppKit
import XCTest
@testable import Throttle

final class ColorsTests: XCTestCase {
    func testBandBoundariesOnTheDisplayedNumber() {
        XCTAssertEqual(Colors.band(forRemaining: 0), .critical)
        XCTAssertEqual(Colors.band(forRemaining: 1), .warning)
        XCTAssertEqual(Colors.band(forRemaining: 20), .warning)
        XCTAssertEqual(Colors.band(forRemaining: 21), .normal)
        XCTAssertEqual(Colors.band(forRemaining: 100), .normal)
    }

    /// "0%" and red are one event: for every used value from -10 to 110 in
    /// hundredths, the text reads 0% exactly when the band is red, and the
    /// band always matches the number the text shows.
    func testZeroPercentTextIffRedExhaustively() {
        for step in -1_000...11_000 {
            let used = Double(step) / 100
            let window = UIFixtures.window("5h", label: "5h", used: used)
            let text = Formatting.percentText(used: used)
            let band = Colors.band(for: window)
            XCTAssertEqual(text == "0%", band == .critical, "used \(used): \(text) vs \(band)")

            if (0...10_000).contains(step) {
                let remaining = Formatting.remainingPercent(used: used)
                XCTAssertEqual(text, "\(remaining)%")
                switch remaining {
                case 21...: XCTAssertEqual(band, .normal, "used \(used)")
                case 1...20: XCTAssertEqual(band, .warning, "used \(used)")
                default: XCTAssertEqual(band, .critical, "used \(used)")
                }
            }
        }
    }

    func testBandColorsAreDistinct() {
        let colors = [UsageBand.normal, .warning, .critical].map {
            Colors.color(for: .percentText, band: $0, dimmed: false)
        }
        XCTAssertEqual(Set(colors).count, 3)
        XCTAssertEqual(colors, [Colors.green, Colors.yellow, Colors.red])
        XCTAssertEqual(Colors.color(for: .barTrack, band: .critical, dimmed: false), Colors.criticalTrack, "an empty bar's track turns red")
        XCTAssertEqual(Colors.color(for: .barTrack, band: .normal, dimmed: false), Colors.track)
        XCTAssertEqual(Colors.color(for: .barTrack, band: .warning, dimmed: false), Colors.track)
    }

    // MARK: Dimming never touches red

    /// "0%" is never shown in anything but red: whether or not the reading
    /// is dimmed, a critical band draws the popup percentage, the bar track,
    /// and the menu bar segment in full-strength red.
    func testCriticalIsFullStrengthRedWhetherDimmedOrNot() {
        for dimmed in [false, true] {
            for part in BandedPart.allCases {
                let ink = Colors.ink(for: part, band: .critical, dimmed: dimmed)
                XCTAssertTrue(ink.isRed, "\(part) dimmed=\(dimmed)")
                XCTAssertEqual(ink.opacity, 1, "\(part) dimmed=\(dimmed) must not fade")
            }
            XCTAssertEqual(Colors.ink(for: .percentText, band: .critical, dimmed: dimmed), BandInk(tone: .red, opacity: 1))
            XCTAssertEqual(Colors.ink(for: .barSegment, band: .critical, dimmed: dimmed), BandInk(tone: .red, opacity: 1))
            XCTAssertEqual(Colors.ink(for: .barTrack, band: .critical, dimmed: dimmed), BandInk(tone: .criticalTrack, opacity: 1))
            XCTAssertEqual(Colors.color(for: .percentText, band: .critical, dimmed: dimmed), Colors.red)
            XCTAssertEqual(Colors.color(for: .barSegment, band: .critical, dimmed: dimmed), Colors.red)
            XCTAssertEqual(Colors.color(for: .barTrack, band: .critical, dimmed: dimmed), Colors.criticalTrack)
        }
    }

    /// Dimming fades or mutes everything that is not red, and nothing that is
    /// not critical ever reads red.
    func testDimmingFadesOnlyTheNonCriticalParts() {
        for band in [UsageBand.normal, .warning] {
            for part in BandedPart.allCases {
                XCTAssertFalse(Colors.ink(for: part, band: band, dimmed: false).isRed, "\(band) \(part)")
                XCTAssertFalse(Colors.ink(for: part, band: band, dimmed: true).isRed, "\(band) \(part)")
                XCTAssertEqual(Colors.ink(for: part, band: band, dimmed: false).opacity, 1, "\(band) \(part)")
            }
            XCTAssertEqual(Colors.ink(for: .percentText, band: band, dimmed: true).tone, .muted)
            XCTAssertEqual(Colors.ink(for: .barSegment, band: band, dimmed: true).tone, .muted)
            XCTAssertLessThan(Colors.ink(for: .barFill, band: band, dimmed: true).opacity, 1)
            XCTAssertLessThan(Colors.ink(for: .barTrack, band: band, dimmed: true).opacity, 1)
        }
    }

    /// Every displayed percentage, dimmed or not: the popup text and the bar
    /// segment are red exactly when the text reads "0%".
    func testZeroPercentIsRedInEveryDimmingState() {
        for remaining in 0...100 {
            let band = Colors.band(forRemaining: remaining)
            for dimmed in [false, true] {
                XCTAssertEqual(Colors.ink(for: .percentText, band: band, dimmed: dimmed).isRed, remaining == 0, "\(remaining)% dimmed=\(dimmed)")
                XCTAssertEqual(Colors.ink(for: .barSegment, band: band, dimmed: dimmed).isRed, remaining == 0, "\(remaining)% dimmed=\(dimmed)")
            }
        }
    }

    /// The red track of an empty bar must read red on the light background,
    /// not as a faint pink.
    func testCriticalTrackReadsRedInLightMode() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let value = hex(Swatch.criticalTrack.nsColor, in: light)
        let red = Int(value >> 16 & 0xFF), green = Int(value >> 8 & 0xFF), blue = Int(value & 0xFF)
        XCTAssertGreaterThanOrEqual(red - green, 90, String(format: "#%06X", value))
        XCTAssertGreaterThanOrEqual(red - blue, 90, String(format: "#%06X", value))
        XCTAssertLessThan(green, 0xA0, "dark enough to read as red, not pink")
    }

    /// Quiet text is body-size, so it keeps 4.5:1 against the light background
    /// and at least 4:1 against the dark one, where it sits a step below the
    /// secondary text as in the reference.
    func testQuietTextContrast() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightText = hex(Swatch.quietText.nsColor, in: light)
        let lightBackground = hex(Swatch.windowBackground.nsColor, in: light)
        XCTAssertGreaterThanOrEqual(contrast(lightText, lightBackground), 4.5)
        let darkText = hex(Swatch.quietText.nsColor, in: dark)
        let darkBackground = hex(Swatch.windowBackground.nsColor, in: dark)
        XCTAssertGreaterThanOrEqual(contrast(darkText, darkBackground), 4.0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double(hex >> shift & 0xFF) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Every swatch resolves to its own dark value under a dark appearance and
    /// its light value under a light one.
    func testSwatchesFollowTheAppearance() throws {
        let expected: [Swatch: (dark: UInt32, light: UInt32)] = [
            .green: (0x25B07F, 0x1C9468),
            .yellow: (0xE8B931, 0xB98A00),
            .red: (0xEF4444, 0xD0312D),
            .windowBackground: (0x191817, 0xFAFAF9),
            .track: (0x2E2D2B, 0xE4E3E0),
            .criticalTrack: (0x7A2B2A, 0xDF7774),
            .divider: (0x2A2927, 0xE7E6E3),
            .quietText: (0x7F7E7C, 0x737270),
        ]
        XCTAssertEqual(Set(expected.keys), Set(Swatch.allCases))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        for swatch in Swatch.allCases {
            let values = try XCTUnwrap(expected[swatch])
            XCTAssertEqual(hex(swatch.nsColor, in: dark), values.dark, "\(swatch) dark")
            XCTAssertEqual(hex(swatch.nsColor, in: light), values.light, "\(swatch) light")
        }
    }

    private func hex(_ color: NSColor, in appearance: NSAppearance) -> UInt32 {
        var result: UInt32 = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let r = UInt32((rgb.redComponent * 255).rounded())
            let g = UInt32((rgb.greenComponent * 255).rounded())
            let b = UInt32((rgb.blueComponent * 255).rounded())
            result = (r << 16) | (g << 8) | b
        }
        return result
    }
}
