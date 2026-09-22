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
        // The unit-test bundle runs inside this app as its host. Starting the
        // real engine there polls the user's real accounts from an ad-hoc
        // signed build, which cannot read the notarized build's Keychain items
        // without a blocking prompt, and the whole suite hangs on it.
        if !Self.isRunningTests {
            model.start()
        }
        _model = State(initialValue: model)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
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
    /// Its number is the account's place in the rotation, which runs over the
    /// same ordered list the detail window numbers.
    private var currentLabel: BarLabel? {
        guard let account = model.rotation.current,
              let number = model.rotation.currentNumber else { return nil }
        return Formatting.barLabel(
            account: account,
            index: number,
            cached: model.rotation.statuses[account.id],
            now: Date()
        )
    }
}
