import XCTest
@testable import Throttle

final class UsageWindowTests: XCTestCase {
    func testLaneKeysAreRecognisedByPrefix() {
        let lane = UsageWindow(key: "lane:spark-5h", label: "Spark 5h", usedPercent: 1, resetsAt: nil, durationSeconds: 18_000)
        let primary = UsageWindow(key: "5h", label: "5h", usedPercent: 1, resetsAt: nil, durationSeconds: 18_000)
        XCTAssertEqual(UsageWindow.lanePrefix, "lane:")
        XCTAssertTrue(lane.isLane)
        XCTAssertFalse(primary.isLane)
    }

    func testModelScopedKeysAreRecognisedByPrefix() {
        let scoped = UsageWindow(key: UsageWindow.scopedPrefix + "Fable", label: "Fable", usedPercent: 1, resetsAt: nil, durationSeconds: 604_800)
        let weekly = UsageWindow(key: "7d", label: "Weekly", usedPercent: 1, resetsAt: nil, durationSeconds: 604_800)
        XCTAssertEqual(UsageWindow.scopedPrefix, "scoped:")
        XCTAssertTrue(scoped.isModelScoped)
        XCTAssertFalse(scoped.isLane)
        XCTAssertFalse(weekly.isModelScoped)
    }

    /// ISC-71 / D-8: lane labels are derived from the reported window length,
    /// never from a hardcoded lane name, because providers have switched lanes
    /// off mid-month.
    func testKnownWindowLengths() {
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 18_000), "5h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 604_800), "Weekly")
    }

    func testHourlyFallbackLabels() {
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 3_600), "1h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 10_800), "3h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 25_200), "7h")
    }

    func testDailyFallbackLabels() {
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 86_400), "1d")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 172_800), "2d")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 2_592_000), "30d")
    }

    /// A sub-hour or ragged window still gets a label rather than an empty
    /// string, so a surprise lane renders instead of vanishing.
    func testRaggedWindowsStillGetALabel() {
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 5_400), "2h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 60), "1h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 0), "1h")
        XCTAssertEqual(UsageWindow.label(forDurationSeconds: 90_000), "25h")
    }

    func testWindowRoundTripsWithAndWithoutResetDate() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let dated = UsageWindow(
            key: "5h",
            label: "5h",
            usedPercent: 42.5,
            resetsAt: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 18_000
        )
        XCTAssertEqual(try decoder.decode(UsageWindow.self, from: encoder.encode(dated)), dated)

        let undated = UsageWindow(
            key: "7d",
            label: "Weekly",
            usedPercent: 0,
            resetsAt: nil,
            durationSeconds: 604_800
        )
        XCTAssertEqual(try decoder.decode(UsageWindow.self, from: encoder.encode(undated)), undated)
    }
}
