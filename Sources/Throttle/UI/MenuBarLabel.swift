import SwiftUI

/// The menu bar item's content: one account per rotation tick (ISC-107),
/// drawn as `<glyph> 1: 5h 100% / WK 89% / FB 79%`.
///
/// `MenuBarExtra` labels are limited to `Text` and `Image`. The provider glyph
/// is a real `Image` beside the text, because an image attached inside a
/// `Text` run is dropped when the status item is rendered. The text itself is
/// built by concatenating `Text` runs, which keep their own `foregroundColor`,
/// so each window segment carries its own band color (ISC-110) while the
/// number and the separators keep the default label color. Only the glyph,
/// the account's number, and the window numbers are ever composed here
/// (ISC-116).
struct MenuBarLabel: View {
    let label: BarLabel?
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: label?.symbolName ?? "gauge.with.dots.needle.33percent")
            text
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 320)
        .onHover(perform: onHover)
    }

    private var text: Text {
        guard let label else {
            return Text(Formatting.emptyBarText)
        }
        var result = Text(label.prefix)
        for (offset, segment) in label.segments.enumerated() {
            if offset > 0 {
                result = result + Text(Formatting.segmentSeparator)
            }
            let piece = Text(segment.text)
            result = result + (label.dimmed ? piece : piece.foregroundColor(Colors.color(for: segment.band)))
        }
        if label.isTruncated {
            result = result + Text(Formatting.overflowMarker)
        }
        return label.dimmed ? result.foregroundColor(.secondary) : result
    }
}
