import XCTest
@testable import Throttle

final class AnthropicParserTests: XCTestCase {
    // MARK: Fixtures

    /// ISC-44, 45, 46, 47, 48, 55: the current `limits[]` shape end to end.
    func testParsesCurrentLimitsFixture() throws {
        let windows = try AnthropicUsageParser.parse(AnthropicFixtures.data("anthropic-limits"))
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable", "scoped:Claude Opus"])
        XCTAssertFalse(windows.contains { $0.durationSeconds == 18_000 })

        XCTAssertEqual(windows[0].key, "7d")
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertEqual(windows[0].usedPercent, 68.04, accuracy: 0.0001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_784_544_000))
        XCTAssertEqual(windows[0].durationSeconds, 604_800)

        XCTAssertEqual(windows[1].key, "scoped:Fable")
        XCTAssertEqual(windows[1].label, "Fable")
        XCTAssertEqual(windows[1].usedPercent, 75.25)
        XCTAssertEqual(windows[1].resetsAt, .iso("2026-07-20T12:00:00Z"))
        XCTAssertEqual(windows[1].durationSeconds, 604_800)

        XCTAssertEqual(windows[2].key, "scoped:Claude Opus")
        XCTAssertEqual(windows[2].label, "Claude Opus")
        XCTAssertEqual(windows[2].usedPercent, 10)
        XCTAssertNil(windows[2].resetsAt)
        XCTAssertEqual(windows[2].durationSeconds, 604_800)
    }

    /// ISC-47, 47.1: legacy `five_hour` / `seven_day` / `seven_day_<model>`.
    func testParsesLegacyFixture() throws {
        let windows = try AnthropicUsageParser.parse(AnthropicFixtures.data("anthropic-legacy"))
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Opus"])
        XCTAssertEqual(windows.map(\.label), ["Weekly", "Opus"])

        XCTAssertEqual(windows[0].usedPercent, 56)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertEqual(windows[0].durationSeconds, 604_800)

        XCTAssertEqual(windows[1].usedPercent, 80.5)
        XCTAssertEqual(windows[1].resetsAt, .iso("2026-07-20T12:00:00Z"))
        XCTAssertEqual(windows[1].durationSeconds, 604_800)
    }

    /// ISC-48: `null` resets keep the window with a nil reset.
    func testParsesInactiveFixtureWithNilResets() throws {
        let windows = try AnthropicUsageParser.parse(AnthropicFixtures.data("anthropic-inactive"))
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable"])
        for window in windows {
            XCTAssertNil(window.resetsAt, "\(window.key) should have no reset")
            XCTAssertEqual(window.usedPercent, 0)
        }
    }

    // MARK: Percent

    func testStringPercentIsAccepted() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_all","percent":"37.5","resets_at":null}]}"#)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 37.5)
    }

    func testOutOfRangeOrNonNumericPercentDropsOnlyThatWindow() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"weekly_all","percent":-1,"resets_at":null},
          {"kind":"weekly_all","percent":100.5,"resets_at":null},
          {"kind":"weekly_scoped","percent":"lots","resets_at":null,"scope":{"model":{"display_name":"A"}}},
          {"kind":"weekly_scoped","percent":true,"resets_at":null,"scope":{"model":{"display_name":"B"}}},
          {"kind":"weekly_scoped","percent":100,"resets_at":null,"scope":{"model":{"display_name":"C"}}}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["scoped:C"])
        XCTAssertEqual(windows[0].usedPercent, 100)
    }

    // MARK: Resets

    func testEpochMillisecondsReset() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_all","percent":1,"resets_at":1784544000123}]}"#)
        XCTAssertEqual(windows[0].resetsAt!.timeIntervalSince1970, 1_784_544_000.123, accuracy: 0.001)
    }

    func testEpochSecondsReset() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_all","percent":1,"resets_at":1784544000}]}"#)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_784_544_000))
    }

    func testFractionalISOReset() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_all","percent":1,"resets_at":"2026-07-13T15:00:00.250Z"}]}"#)
        XCTAssertEqual(windows[0].resetsAt!.timeIntervalSince1970, Date.iso("2026-07-13T15:00:00Z").timeIntervalSince1970 + 0.25, accuracy: 0.001)
    }

    func testAbsentResetKeyKeepsWindow() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_all","percent":5}]}"#)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].resetsAt)
    }

    /// ISC-48: a present but unparseable reset is corruption; drop that window only.
    func testMalformedResetDropsWindow() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"weekly_all","percent":5,"resets_at":"next tuesday"},
          {"kind":"weekly_all","percent":6,"resets_at":{"weird":true}},
          {"kind":"weekly_scoped","percent":7,"resets_at":null,"scope":{"model":{"display_name":"Kept"}}}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["scoped:Kept"])
    }

    // MARK: Shape rules

    /// ISC-49: never an empty `.ok`.
    func testZeroWindowsThrowsInvalidResponse() {
        assertNoUsableWindows(#"{"limits":[]}"#)
        assertNoUsableWindows(#"{"limits":[{"kind":"weekly_all","percent":"nope"}]}"#)
        assertNoUsableWindows(#"{"limits":[{"kind":"unknown_kind","percent":5}]}"#)
        assertNoUsableWindows(#"{"something_else":1}"#)
        assertNoUsableWindows(#"{}"#)
    }

    func testMalformedJSONThrowsInvalidResponse() {
        XCTAssertThrowsError(try parse("not json")) { error in
            guard case UsageError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        XCTAssertThrowsError(try parse("[1,2,3]")) { error in
            guard case UsageError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testCapsAtTwelveWindowsAndBoundsLabels() throws {
        let longName = String(repeating: "x", count: 200)
        var entries = [
            #"{"kind":"session","percent":1,"resets_at":null}"#,
            #"{"kind":"weekly_all","percent":2,"resets_at":null}"#,
        ]
        for i in 0..<20 {
            entries.append(#"{"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"\#(i)-\#(longName)"}}}"#)
        }
        let windows = try parse("{\"limits\":[\(entries.joined(separator: ","))]}")
        XCTAssertEqual(windows.count, 12)
        XCTAssertEqual(windows[0].key, "7d")
        XCTAssertFalse(windows.contains { $0.key == "5h" })
        for window in windows {
            XCTAssertLessThanOrEqual(window.label.count, 80)
        }
    }

    func testFirstOccurrencePerKeyWins() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"weekly_all","percent":10,"resets_at":null},
          {"kind":"weekly_all","percent":90,"resets_at":null},
          {"kind":"weekly_scoped","percent":20,"resets_at":null,"scope":{"model":{"display_name":"M"}}},
          {"kind":"weekly_scoped","percent":80,"resets_at":null,"scope":{"model":{"display_name":"M"}}}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:M"])
        XCTAssertEqual(windows.map(\.usedPercent), [10, 20])
    }

    func testScopedWithoutDisplayNameGetsDefaultLabel() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_scoped","percent":3,"resets_at":null}]}"#)
        XCTAssertEqual(windows[0].key, "scoped:Scoped")
        XCTAssertEqual(windows[0].label, "Scoped")
    }

    /// ISC-55: Weekly, then scoped in payload order regardless of payload order for the fixed lanes.
    func testDisplayOrderIsWeeklyThenScopedInPayloadOrder() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"weekly_scoped","percent":1,"resets_at":null,"scope":{"model":{"display_name":"Zed"}}},
          {"kind":"weekly_all","percent":2,"resets_at":null},
          {"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"Alpha"}}},
          {"kind":"session","percent":4,"resets_at":null}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Zed", "scoped:Alpha"])
    }

    /// ISC-47.1: every `seven_day_<suffix>` becomes a scoped window, in payload order.
    func testLegacyScopedSuffixesInPayloadOrder() throws {
        let windows = try parse("""
        {
          "seven_day_sonnet": {"utilization": 30, "resets_at": null},
          "seven_day": {"utilization": 20, "resets_at": null},
          "seven_day_haiku": {"utilization": 40, "resets_at": null},
          "five_hour": {"utilization": 10, "resets_at": null}
        }
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Sonnet", "scoped:Haiku"])
        XCTAssertEqual(windows.map(\.label), ["Weekly", "Sonnet", "Haiku"])
        XCTAssertEqual(windows.map(\.usedPercent), [20, 30, 40])
    }

    // MARK: Retired session limit

    /// Anthropic retired the 5-hour limit but still sends a `session` entry /
    /// `five_hour` object. None of it may surface, whatever its percent or reset.
    func testSessionEntryAtZeroWithNoResetIsDropped() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"session","percent":0,"resets_at":null,"is_active":true},
          {"kind":"weekly_all","percent":12,"resets_at":"2026-07-20T12:00:00Z"},
          {"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable"])
    }

    func testSessionEntryWithPercentAndResetIsDropped() throws {
        let windows = try parse("""
        {"limits":[
          {"kind":"session","percent":13,"resets_at":"2026-07-13T15:00:00Z","is_active":true},
          {"kind":"weekly_all","percent":12,"resets_at":"2026-07-20T12:00:00Z"},
          {"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}
        ]}
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable"])
    }

    func testLegacyFiveHourAtZeroWithNoResetIsDropped() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 0, "resets_at": null},
          "seven_day": {"utilization": 20, "resets_at": null},
          "seven_day_fable": {"utilization": 30, "resets_at": null}
        }
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable"])
    }

    func testLegacyFiveHourWithPercentAndResetIsDropped() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 13, "resets_at": "2026-07-13T18:00:00Z"},
          "seven_day": {"utilization": 20, "resets_at": null},
          "seven_day_fable": {"utilization": 30, "resets_at": null}
        }
        """)
        XCTAssertEqual(windows.map(\.key), ["7d", "scoped:Fable"])
    }

    func testSessionOnlyPayloadHasNoUsableWindows() {
        assertNoUsableWindows(#"{"limits":[{"kind":"session","percent":42,"resets_at":"2026-07-13T15:00:00Z"}]}"#)
        assertNoUsableWindows(#"{"limits":[{"kind":"session","percent":0,"resets_at":null}]}"#)
        assertNoUsableWindows(#"{"five_hour":{"utilization":42,"resets_at":"2026-07-13T18:00:00Z"}}"#)
        assertNoUsableWindows(#"{"five_hour":{"utilization":0,"resets_at":null}}"#)
    }

    // MARK: Helpers

    private func parse(_ text: String) throws -> [UsageWindow] {
        try AnthropicUsageParser.parse(Data(text.utf8))
    }

    private func assertNoUsableWindows(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: line) { error in
            guard case UsageError.invalidResponse(let reason) = error else {
                return XCTFail("expected invalidResponse, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(reason, "no usable windows", file: file, line: line)
        }
    }
}
