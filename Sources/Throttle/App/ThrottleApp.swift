import SwiftUI

/// Throttle is an accessory (`LSUIElement`) app: its only scene is the menu bar
/// item, so launching it never opens a window and never shows a Dock icon
/// (ISC-106). The label rotates through the accounts (F9); the window is the
/// account detail (F10).
@main
struct ThrottleApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            DetailWindow(model: model)
        } label: {
            MenuBarLabel(label: currentLabel) { hovering in
                model.rotation.isPaused = hovering
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The label for the account on display, rebuilt from cached data only.
    private var currentLabel: BarLabel? {
        guard let account = model.rotation.current else { return nil }
        return Formatting.barLabel(
            account: account,
            cached: model.rotation.statuses[account.id],
            showRemaining: model.settings.showRemaining,
            now: Date()
        )
    }
}
