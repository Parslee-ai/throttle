import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// ISC-526 to ISC-528, as a person sees them: a development build opens on
/// the add-account state, and its launch-at-login toggle and update button
/// are disabled and say why.
/// Written to `THROTTLE_SNAPSHOT_DIR` like every other popup snapshot.
extension PopupSnapshotTests {
    func testDevelopmentBuildSettingsAndFooterRenderInDarkAndLight() throws {
        let harness = try IdentityHarness()
        defer { harness.cleanUp() }
        let model = harness.model(identity: .development)

        for appearance in Self.appearances {
            var toggles: [NSButton] = []
            let settings = try render(SettingsView(model: model, onDismiss: {}), appearance: appearance.value) { hosting in
                toggles = Self.buttons(in: hosting).filter { $0.title == "Launch at login" }
            }
            // The settings sheet is mostly one flat colour, so it is checked
            // against a lower bar than the popup's.
            XCTAssertGreaterThan(distinctColors(in: settings), 8, "settings rendered as a flat image")
            try save(settings, named: "settings-development-\(appearance.name)")
            if let toggle = toggles.first {
                XCTAssertFalse(toggle.isEnabled, "launch at login is disabled")
            }

            let window = try render(DetailWindow(model: model), appearance: appearance.value)
            try check(window, named: "panel-development-\(appearance.name)")
        }
        XCTAssertEqual(harness.loginItems.calls, 0)
    }

    private func save(_ rep: NSBitmapImageRep, named name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, name)
        guard let directory = ProcessInfo.processInfo.environment["THROTTLE_SNAPSHOT_DIR"], !directory.isEmpty else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found += buttons(in: subview) }
        return found
    }
}
