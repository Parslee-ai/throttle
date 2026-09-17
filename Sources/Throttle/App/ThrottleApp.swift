import SwiftUI

/// Throttle is an accessory (`LSUIElement`) app: its only scene is the menu bar
/// item, so launching it never opens a window and never shows a Dock icon.
///
/// The menu content here is a placeholder. The rotating bar label (F9) and the
/// account detail window (F10) replace it.
@main
struct ThrottleApp: App {
    var body: some Scene {
        MenuBarExtra("Throttle", systemImage: "gauge.with.dots.needle.33percent") {
            Text("Throttle")
        }
    }
}
