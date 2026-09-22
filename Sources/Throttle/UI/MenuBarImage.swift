import AppKit

/// Draws the menu bar label as one image: the provider glyph, `1: `, and the
/// window segments in their band colors.
///
/// `MenuBarExtra` turns a SwiftUI label into the status button's plain title
/// and template image, which drops every text color, so the colored label
/// has to reach the menu bar as a non-template image. The image draws with
/// dynamic colors resolved when it is drawn, so it follows the menu bar's own
/// light or dark appearance, which can differ from the system setting.
enum MenuBarImage {
    /// Height of the image, the height of other menu extras' content.
    static let height: CGFloat = 18
    /// Space between the glyph and the text.
    static let glyphGap: CGFloat = 4
    /// Used when there is no account to show.
    static let emptySymbolName = "gauge.with.dots.needle.33percent"

    /// The menu bar font with digits that keep their width, so a rotating
    /// percentage does not jitter.
    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// Color for everything that is not a window segment: the number, the
    /// separators, the overflow marker, and the glyph.
    static func neutralColor(dimmed: Bool) -> NSColor {
        dimmed ? .secondaryLabelColor : .labelColor
    }

    /// The label's text with one color per run: neutral for the number and
    /// separators, `Colors.ink` for each segment (so a critical segment is
    /// full red even when the label is dimmed).
    static func attributedText(for label: BarLabel?, font: NSFont = MenuBarImage.font) -> NSAttributedString {
        let neutral = neutralColor(dimmed: label?.dimmed ?? false)
        func run(_ text: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }

        guard let label else {
            return run(Formatting.emptyBarText, neutral)
        }
        let result = NSMutableAttributedString(attributedString: run(label.prefix, neutral))
        for (offset, segment) in label.segments.enumerated() {
            if offset > 0 {
                result.append(run(Formatting.segmentSeparator, neutral))
            }
            let ink = Colors.ink(for: .barSegment, band: segment.band, dimmed: label.dimmed)
            result.append(run(segment.text, Colors.nsColor(for: ink)))
        }
        if label.isTruncated {
            result.append(run(Formatting.overflowMarker, neutral))
        }
        return result
    }

    /// The whole label as one non-template image, sized to its content.
    static func image(for label: BarLabel?) -> NSImage {
        let font = font
        let text = attributedText(for: label, font: font)
        let textSize = text.size()
        let symbolName = label?.symbolName ?? emptySymbolName
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        let symbolSize = symbol?.size ?? .zero
        let glyphWidth = symbol == nil ? 0 : ceil(symbolSize.width) + glyphGap
        let size = NSSize(
            width: ceil(glyphWidth + textSize.width),
            height: max(height, ceil(textSize.height))
        )
        let dimmed = label?.dimmed ?? false

        let image = NSImage(size: size, flipped: false) { bounds in
            if let symbol {
                // Resolve the neutral color now, in the appearance this draw
                // runs in, and paint the glyph with it.
                let color = neutralColor(dimmed: dimmed).usingColorSpace(.sRGB) ?? .labelColor
                let tinted = symbol.withSymbolConfiguration(
                    symbolConfiguration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                ) ?? symbol
                let origin = NSPoint(x: 0, y: floor((bounds.height - symbolSize.height) / 2))
                tinted.draw(in: NSRect(origin: origin, size: symbolSize))
            }
            let textOrigin = NSPoint(x: glyphWidth, y: floor((bounds.height - textSize.height) / 2))
            text.draw(in: NSRect(origin: textOrigin, size: textSize))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label?.plainText ?? Formatting.emptyBarText
        return image
    }
}
