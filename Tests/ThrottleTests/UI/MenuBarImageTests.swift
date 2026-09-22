import AppKit
import XCTest
@testable import Throttle

/// The menu bar label is one non-template image, because the status item
/// drops `Text` colors. These tests read its attributed text run by run and
/// look for red in its pixels.
final class MenuBarImageTests: XCTestCase {
    private let now = UIFixtures.now

    private func label(_ windows: [UsageWindow], index: Int = 1, isStale: Bool = false) -> BarLabel {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: windows, isStale: isStale)
        return Formatting.barLabel(account: account, index: index, cached: cached, now: now)
    }

    private var mixed: [UsageWindow] {
        [
            UIFixtures.window("5h", label: "5h", used: 0),
            UIFixtures.window("7d", label: "Weekly", used: 85),
            UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: 100),
        ]
    }

    // MARK: Attributed text

    func testRunsAndColors() throws {
        let text = MenuBarImage.attributedText(for: label(mixed))
        XCTAssertEqual(text.string, "1: 5h 100% / WK 15% / FB 0%")

        XCTAssertEqual(try color(of: "1: ", in: text), NSColor.labelColor)
        XCTAssertEqual(try color(of: " / ", in: text), NSColor.labelColor)

        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(hex(try color(of: "5h 100%", in: text), in: dark), 0x25B07F)
        XCTAssertEqual(hex(try color(of: "5h 100%", in: text), in: light), 0x1C9468)
        XCTAssertEqual(hex(try color(of: "WK 15%", in: text), in: dark), 0xE8B931)
        XCTAssertEqual(hex(try color(of: "WK 15%", in: text), in: light), 0xB98A00)
        XCTAssertEqual(hex(try color(of: "FB 0%", in: text), in: dark), 0xEF4444)
        XCTAssertEqual(hex(try color(of: "FB 0%", in: text), in: light), 0xD0312D)

        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, NSFont.menuBarFont(ofSize: 0).pointSize)
    }

    /// A stale label draws secondary, except that 0% keeps its red.
    func testDimmedLabelIsSecondaryButZeroStaysRed() throws {
        let text = MenuBarImage.attributedText(for: label(mixed, isStale: true))
        XCTAssertEqual(try color(of: "1: ", in: text), NSColor.secondaryLabelColor)
        XCTAssertEqual(try color(of: "5h 100%", in: text), NSColor.secondaryLabelColor)
        XCTAssertEqual(try color(of: "WK 15%", in: text), NSColor.secondaryLabelColor)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(hex(try color(of: "FB 0%", in: text), in: dark), 0xEF4444)
        XCTAssertEqual(hex(try color(of: "FB 0%", in: text), in: light), 0xD0312D)
    }

    func testTruncatedLabelAndEmptyBar() throws {
        let many = mixed + [
            UIFixtures.window(UsageWindow.scopedPrefix + "Opus", label: "Opus", used: 0),
            UIFixtures.window(UsageWindow.scopedPrefix + "Sonnet", label: "Sonnet", used: 0),
        ]
        let truncated = label(many, index: 12)
        XCTAssertTrue(truncated.isTruncated)
        let text = MenuBarImage.attributedText(for: truncated)
        XCTAssertEqual(text.string, truncated.plainText)
        XCTAssertTrue(text.string.hasSuffix(Formatting.overflowMarker))
        XCTAssertEqual(try color(of: Formatting.overflowMarker, in: text), NSColor.labelColor)

        let empty = MenuBarImage.attributedText(for: nil)
        XCTAssertEqual(empty.string, Formatting.emptyBarText)
    }

    func testStateMarkerKeepsItsWarningColor() throws {
        let account = UIFixtures.account("me@example.com")
        let cached = UIFixtures.cached(for: account, windows: [], state: .needsLogin)
        let text = MenuBarImage.attributedText(for: Formatting.barLabel(account: account, index: 3, cached: cached, now: now))
        XCTAssertEqual(text.string, "3: ⚠︎ login")
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(hex(try color(of: "⚠︎ login", in: text), in: dark), 0xE8B931)
    }

    // MARK: Image

    func testImageIsNonTemplateAndDescribesItself() {
        let bar = label(mixed)
        let image = MenuBarImage.image(for: bar)
        XCTAssertFalse(image.isTemplate, "a template image would be tinted one color by the menu bar")
        XCTAssertEqual(image.accessibilityDescription, "1: 5h 100% / WK 15% / FB 0%")
        XCTAssertEqual(image.size.height, MenuBarImage.height)
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertLessThan(image.size.width, 320)
        XCTAssertEqual(MenuBarImage.image(for: nil).accessibilityDescription, Formatting.emptyBarText)
    }

    /// The pixels carry the color: red for a 0% segment, in both menu bar
    /// appearances, and no red at all for an all-green label.
    func testZeroPercentDrawsRedPixelsAndGreenDrawsNone() throws {
        let zero = MenuBarImage.image(for: label([UIFixtures.window("7d", label: "Weekly", used: 100)]))
        let staleZero = MenuBarImage.image(for: label([UIFixtures.window("7d", label: "Weekly", used: 100)], isStale: true))
        let green = MenuBarImage.image(for: label([
            UIFixtures.window("5h", label: "5h", used: 0),
            UIFixtures.window("7d", label: "Weekly", used: 30),
        ]))
        for appearance in [NSAppearance(named: .darkAqua)!, NSAppearance(named: .aqua)!] {
            let name = appearance.name.rawValue
            XCTAssertGreaterThan(MenuBarRendering.count(in: try MenuBarRendering.render([zero], appearance: appearance), where: MenuBarRendering.isRed), 20, name)
            XCTAssertGreaterThan(MenuBarRendering.count(in: try MenuBarRendering.render([staleZero], appearance: appearance), where: MenuBarRendering.isRed), 20, "\(name), dimmed")
            let greenRender = try MenuBarRendering.render([green], appearance: appearance)
            XCTAssertEqual(MenuBarRendering.count(in: greenRender, where: MenuBarRendering.isRed), 0, name)
            XCTAssertGreaterThan(MenuBarRendering.count(in: greenRender, where: MenuBarRendering.isGreen), 20, name)
        }
    }

    // MARK: Helpers

    private func color(of substring: String, in text: NSAttributedString) throws -> NSColor {
        let range = (text.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "\(substring) in \(text.string)")
        var effective = NSRange()
        let value = text.attribute(.foregroundColor, at: range.location, effectiveRange: &effective)
        XCTAssertTrue(NSLocationInRange(NSMaxRange(range) - 1, effective), "\(substring) is one run")
        return try XCTUnwrap(value as? NSColor)
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

/// Draws menu bar images the way the status item does: into a bitmap, in a
/// given appearance, over a menu-bar-like background.
enum MenuBarRendering {
    static let scale: CGFloat = 2

    static func render(_ images: [NSImage], appearance: NSAppearance, padding: CGFloat = 8, spacing: CGFloat = 6) throws -> NSBitmapImageRep {
        let width = (images.map(\.size.width).max() ?? 0) + padding * 2
        let height = images.reduce(0) { $0 + $1.size.height } + spacing * CGFloat(max(0, images.count - 1)) + padding * 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((width * scale).rounded(.up)),
            pixelsHigh: Int((height * scale).rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            Swatch.windowBackground.nsColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
            var top = height - padding
            for image in images {
                top -= image.size.height
                image.draw(in: NSRect(x: padding, y: top, width: image.size.width, height: image.size.height))
                top -= spacing
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func count(in rep: NSBitmapImageRep, where matches: (Int, Int, Int) -> Bool) -> Int {
        var total = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(color.redComponent * 255), g = Int(color.greenComponent * 255), b = Int(color.blueComponent * 255)
                if matches(r, g, b) { total += 1 }
            }
        }
        return total
    }

    static func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        r >= 150 && r - g >= 90 && r - b >= 90
    }

    static func isGreen(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        g >= 120 && g - r >= 70
    }
}
