import XCTest
@testable import Throttle

final class ColorsTests: XCTestCase {
    func testBandThresholds() {
        XCTAssertEqual(Colors.band(for: 0), .normal)
        XCTAssertEqual(Colors.band(for: 69.9), .normal)
        XCTAssertEqual(Colors.band(for: 70), .warning)
        XCTAssertEqual(Colors.band(for: 89.9), .warning)
        XCTAssertEqual(Colors.band(for: 90), .critical)
        XCTAssertEqual(Colors.band(for: 100), .critical)
    }

    func testNormalBandLeavesLabelColorAlone() {
        XCTAssertNil(Colors.color(for: .normal))
        XCTAssertNotNil(Colors.color(for: .warning))
        XCTAssertNotNil(Colors.color(for: .critical))
        XCTAssertNotEqual(Colors.color(for: .warning), Colors.color(for: .critical))
    }

    func testWorstBandPicksTheHighestWindow() {
        let windows = [
            UIFixtures.window("5h", label: "5h", used: 45),
            UIFixtures.window("7d", label: "Weekly", used: 75),
        ]
        XCTAssertEqual(Colors.worstBand(of: windows), .warning)
        XCTAssertEqual(Colors.worstBand(of: windows + [UIFixtures.window("x", label: "x", used: 95)]), .critical)
        XCTAssertEqual(Colors.worstBand(of: []), .normal)
    }
}
