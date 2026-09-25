import XCTest

/// The detail window is a menu bar panel that closes when it stops being the
/// key window. A sheet, alert, dialog, popover, or modal panel is a window of
/// its own: clicking in it takes key from the panel and closes it under the
/// user. Every question and form is a panel modal (`UI/PanelModal.swift`)
/// instead, drawn inside the panel's own view hierarchy.
final class NoWindowModalsTests: XCTestCase {
    private let windowModals = [
        ".sheet(",
        ".alert(",
        ".confirmationDialog(",
        ".popover(",
        ".fileImporter(",
        ".fileExporter(",
        "NSAlert",
        "runModal",
        "NSOpenPanel",
        "NSSavePanel",
    ]

    func testNoSourcePresentsAModalInAWindowOfItsOwn() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() where !line.isComment && line.containsAny(windowModals) {
            offenders.append("\(line.location): \(line.trimmed)")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report("A modal that opens its own window closes the menu bar panel; use panelModal:", offenders)
        )
    }
}
