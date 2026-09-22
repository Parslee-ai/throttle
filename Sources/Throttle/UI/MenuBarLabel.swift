import SwiftUI

/// The menu bar item's content: one account per rotation tick (ISC-107),
/// drawn as `<glyph> 1: 5h 100% / WK 89% / FB 79%`.
///
/// The label is a single image (`MenuBarImage`). `MenuBarExtra` maps a
/// SwiftUI label onto the status button's plain title and template image, so
/// `Text` colors never reach the menu bar; a non-template image keeps each
/// window segment in its band color (ISC-110), with red kept even when the
/// label is dimmed. Only the glyph, the account's number, and the window
/// numbers are ever drawn here (ISC-116).
struct MenuBarLabel: View {
    let label: BarLabel?
    let onHover: (Bool) -> Void

    var body: some View {
        Image(nsImage: MenuBarImage.image(for: label))
            // The image carries its own colors; never let it be tinted.
            .renderingMode(.original)
            .accessibilityLabel(Text(label?.plainText ?? Formatting.emptyBarText))
            .onHover(perform: onHover)
    }
}
