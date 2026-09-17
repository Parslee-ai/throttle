import XCTest
@testable import Throttle

final class PollSettingsTests: XCTestCase {
    func testDefaultsMatchTheISA() {
        let settings = PollSettings()
        XCTAssertEqual(settings.pollInterval, 300)
        XCTAssertEqual(settings.perAccountTimeout, 15)
        XCTAssertEqual(settings.cycleDeadline, 60)
        XCTAssertEqual(settings.staleAfterFactor, 2)
        XCTAssertEqual(settings.stagger, 2)
        XCTAssertEqual(settings.staleAfter, 600)
    }

    func testIntervalIsClampedOnInitAndOnAssignment() {
        XCTAssertEqual(PollSettings(pollInterval: 5).pollInterval, 60)
        XCTAssertEqual(PollSettings(pollInterval: 10_000).pollInterval, 1_800)
        XCTAssertEqual(PollSettings(pollInterval: .nan).pollInterval, 300)
        var settings = PollSettings()
        settings.pollInterval = 1
        XCTAssertEqual(settings.pollInterval, 60)
        settings.pollInterval = 900
        XCTAssertEqual(settings.pollInterval, 900)
    }

    func testDecodingClampsAndFillsMissingKeys() throws {
        let json = Data(#"{"pollInterval": 5}"#.utf8)
        let settings = try JSONDecoder().decode(PollSettings.self, from: json)
        XCTAssertEqual(settings.pollInterval, 60)
        XCTAssertEqual(settings.perAccountTimeout, 15)
        XCTAssertEqual(settings.stagger, 2)
    }

    func testRoundTrip() throws {
        let original = PollSettings(pollInterval: 120, perAccountTimeout: 10, cycleDeadline: 45, staleAfterFactor: 3, stagger: 1)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PollSettings.self, from: data), original)
    }
}
