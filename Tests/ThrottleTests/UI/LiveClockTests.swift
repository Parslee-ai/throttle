import AppKit
import SwiftUI
import XCTest
@testable import Throttle

@MainActor
final class LiveClockTests: XCTestCase {
    @Observable final class Box { var tick = 0 }

    /// The detail window's rows must get the wall clock at render time, even
    /// when the periodic schedule's last entry is old (ticks pause while the
    /// MenuBarExtra window is hidden) and a data change forces a re-render.
    func testRowsGetRenderTimeClockAfterDataDrivenRerender() async throws {
        let box = Box()
        var seen: [(now: Date, wall: Date)] = []
        let start = Date().addingTimeInterval(-600)
        let root = LiveClock(from: start, every: 30) { now -> Text in
            _ = box.tick
            seen.append((now, Date()))
            return Text("x")
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let rendersBefore = seen.count
        box.tick += 1
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()

        // Without a render after the data change, the lag below proves nothing.
        XCTAssertGreaterThan(seen.count, rendersBefore, "the data change never re-rendered the rows")
        let last = try XCTUnwrap(seen.last)
        let lag = last.wall.timeIntervalSince(last.now)
        print("MEASURED LAG \(lag)s over \(seen.count) renders")
        XCTAssertLessThan(lag, 1.0, "rows were handed a clock \(lag)s behind the wall clock")
    }
}
