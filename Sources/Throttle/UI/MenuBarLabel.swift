import SwiftUI

/// The menu bar item's content: one account per rotation tick (ISC-107).
///
/// `MenuBarExtra` labels are limited to `Text` and `Image`. The provider glyph
/// is a real `Image` beside the text, because an image attached inside a
/// `Text` run is dropped when the status item is rendered. The text itself is
/// built by concatenating `Text` runs, which keep their own `foregroundColor`,
/// so each window percentage carries its own band color (ISC-110). Only the
/// glyph, the email, and the window numbers are ever composed here (ISC-116).
struct MenuBarLabel: View {
    let label: BarLabel?
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: label?.symbolName ?? "gauge.with.dots.needle.33percent")
            text
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 320)
        .onHover(perform: onHover)
    }

    private var text: Text {
        guard let label else {
            return Text(Formatting.emptyBarText)
        }
        var result = Text(label.email)
        for segment in label.segments {
            let piece = Text(Formatting.segmentSeparator + segment.text)
            if label.dimmed {
                result = result + piece.foregroundColor(.secondary)
            } else if let color = Colors.color(for: segment.band) {
                result = result + piece.foregroundColor(color)
            } else {
                result = result + piece
            }
        }
        return label.dimmed ? result.foregroundColor(.secondary) : result
    }
}
