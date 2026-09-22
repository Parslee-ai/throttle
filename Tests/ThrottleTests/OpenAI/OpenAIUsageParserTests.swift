import XCTest
@testable import Throttle

final class OpenAIUsageParserTests: XCTestCase {
    /// ISC-71/72/73/76: the captured fixture parses into one primary window
    /// (the 5-hour lane was off when it was captured) and one extra lane with
    /// both sub-windows.
    func testParsesCapturedFixture() throws {
        let snapshot = try OpenAIUsageParser.parse(try OpenAIFixtures.whamUsage())

        XCTAssertEqual(snapshot.windows.count, 1, "secondary_window is null and must be skipped, not failed")
        let weekly = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(weekly.key, "7d")
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.usedPercent, 33)
        XCTAssertEqual(weekly.durationSeconds, 604_800)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_788_137_068))

        XCTAssertEqual(snapshot.additionalWindows.count, 2)
        XCTAssertEqual(snapshot.additionalWindows.map(\.key), [
            "lane:GPT-5.3-Codex-Spark:5h",
            "lane:GPT-5.3-Codex-Spark:7d",
        ])
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "GPT-5.3-Codex-Spark 5h",
            "GPT-5.3-Codex-Spark Weekly",
        ])
        XCTAssertEqual(snapshot.additionalWindows.map(\.usedPercent), [0, 0])
        XCTAssertEqual(snapshot.additionalWindows.map(\.durationSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.additionalWindows[0].resetsAt, Date(timeIntervalSince1970: 1_787_636_851))
        XCTAssertEqual(snapshot.additionalWindows[1].resetsAt, Date(timeIntervalSince1970: 1_788_223_651))

        XCTAssertEqual(snapshot.email, "redacted@example.com")
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.accountID, "00000000-0000-0000-0000-000000000000")
    }

    func testBothWindowsSortShortestFirst() throws {
        // Deliberately put the weekly window in the primary slot.
        let json = OpenAIFixtures.synthetic(primarySeconds: 604_800, secondarySeconds: 18_000)
        let snapshot = try OpenAIUsageParser.parse(Data(json.utf8))

        XCTAssertEqual(snapshot.windows.map(\.key), ["5h", "7d"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["5h", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.durationSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 80)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 12.5)
        XCTAssertTrue(snapshot.additionalWindows.isEmpty)
        XCTAssertEqual(snapshot.planType, "plus")
    }

    /// D-8: an unfamiliar window length still yields a usable window, with a
    /// label derived from its length rather than looked up by lane name.
    func testUnknownDurationIsLabeledFromLength() throws {
        let json = OpenAIFixtures.synthetic(primarySeconds: 3_600, secondarySeconds: 172_800)
        let snapshot = try OpenAIUsageParser.parse(Data(json.utf8))

        XCTAssertEqual(snapshot.windows.map(\.key), ["1h", "2d"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["1h", "2d"])
    }

    func testUsedPercentIsClamped() throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 140, "limit_window_seconds": 18000, "reset_at": 1},
                        "secondary_window": {"used_percent": -3, "limit_window_seconds": 604800, "reset_at": 2}}}
        """
        let snapshot = try OpenAIUsageParser.parse(Data(json.utf8))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [100, 0])
    }

    func testResetAtFallsBackToResetAfterWhenNowSupplied() throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_after_seconds": 90},
                        "secondary_window": null}}
        """
        let now = Date(timeIntervalSince1970: 1_000)
        let withNow = try OpenAIUsageParser.parse(Data(json.utf8), now: now)
        XCTAssertEqual(withNow.windows[0].resetsAt, Date(timeIntervalSince1970: 1_090))

        let withoutNow = try OpenAIUsageParser.parse(Data(json.utf8))
        XCTAssertNil(withoutNow.windows[0].resetsAt)
    }

    func testAdditionalLanesSurviveWhenPrimaryIsEmpty() throws {
        let lanes = """
        [{"limit_name": "Spark", "rate_limit": {"primary_window": {"used_percent": 5, "limit_window_seconds": 18000, "reset_at": 10}, "secondary_window": null}}]
        """
        let json = OpenAIFixtures.synthetic(primarySeconds: nil, secondarySeconds: nil, additional: lanes)
        let snapshot = try OpenAIUsageParser.parse(Data(json.utf8))
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.additionalWindows.map(\.key), ["lane:Spark:5h"])
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["Spark 5h"])
    }

    func testNoWindowsAtAllIsInvalidResponse() {
        let json = OpenAIFixtures.synthetic(primarySeconds: nil, secondarySeconds: nil)
        XCTAssertThrowsError(try OpenAIUsageParser.parse(Data(json.utf8))) { error in
            guard case UsageError.invalidResponse(let reason) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertEqual(reason, "no usable windows")
        }
    }

    func testNonJSONIsInvalidResponse() {
        XCTAssertThrowsError(try OpenAIUsageParser.parse(Data("<html>login</html>".utf8))) { error in
            guard case UsageError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    /// The manual-reset count rides along from `rate_limit_reset_credits`.
    func testParsesTheResetCreditCount() throws {
        let snapshot = try OpenAIUsageParser.parse(try OpenAIFixtures.whamUsage())
        XCTAssertEqual(snapshot.resetCreditsAvailable, 1)
    }

    func testResetCreditCountIsNilWhenAbsentOrUnusable() throws {
        let window = #""rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_at": 5}, "secondary_window": null}"#
        XCTAssertNil(try OpenAIUsageParser.parse(Data("{\(window)}".utf8)).resetCreditsAvailable, "absent")

        let oddShapes = [
            #""rate_limit_reset_credits": "many""#,
            #""rate_limit_reset_credits": {"available_count": "two"}"#,
            #""rate_limit_reset_credits": {"available_count": -1}"#,
            #""rate_limit_reset_credits": null"#,
        ]
        for credits in oddShapes {
            let snapshot = try OpenAIUsageParser.parse(Data("{\(credits), \(window)}".utf8))
            XCTAssertNil(snapshot.resetCreditsAvailable, credits)
            XCTAssertEqual(snapshot.windows.count, 1, "an odd credit shape never costs the windows: \(credits)")
        }

        let two = #"{"rate_limit_reset_credits": {"available_count": 2, "applicable_available_count": 0}, "# + window + "}"
        XCTAssertEqual(try OpenAIUsageParser.parse(Data(two.utf8)).resetCreditsAvailable, 2)
    }

    func testKeyDerivation() {
        XCTAssertEqual(OpenAIUsageParser.key(forDurationSeconds: 18_000), "5h")
        XCTAssertEqual(OpenAIUsageParser.key(forDurationSeconds: 604_800), "7d")
        XCTAssertEqual(OpenAIUsageParser.key(forDurationSeconds: 3_600), "1h")
        XCTAssertEqual(OpenAIUsageParser.key(forDurationSeconds: 259_200), "3d")
    }
}
