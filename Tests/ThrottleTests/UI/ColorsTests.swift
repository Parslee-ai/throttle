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
        let colors = [UsageBand.normal, .warning, .critical].map(Colors.color(for:))
        XCTAssertEqual(Set(colors).count, 3)
        XCTAssertNotEqual(Colors.track(for: .critical), Colors.track(for: .normal), "an empty bar's track turns red")
        XCTAssertEqual(Colors.track(for: .normal), Colors.track(for: .warning))
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
            .divider: (0x2A2927, 0xE7E6E3),
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
