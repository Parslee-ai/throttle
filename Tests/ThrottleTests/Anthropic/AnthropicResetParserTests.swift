import XCTest
@testable import Throttle

/// The banked-reset block of the Claude usage payload: the count it yields,
/// the grant a reset would spend, and that nothing in it can break the
/// window reading.
final class AnthropicResetParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try AnthropicFixtures.data(name)
    }

    /// The clean fixture's root with `cedar_ember` set to `block`.
    private func cleanBody(withBlock block: Any) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture("anthropic-limits")) as? [String: Any])
        root[AnthropicResetParser.blockKey] = block
        return try JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])
    }

    private func grants(_ json: String) -> AnthropicResetGrants {
        AnthropicResetParser.parse(Data(json.utf8))
    }

    // MARK: Count

    func testTwoGrantsOfOneAndTwoYieldThree() throws {
        let body = try fixture("anthropic-resets-two-grants")
        XCTAssertEqual(AnthropicResetParser.parse(body).count, 3)
        XCTAssertEqual(try AnthropicUsageParser.parse(body), try AnthropicUsageParser.parse(try fixture("anthropic-limits")))
    }

    func testIneligibleYieldsNoCount() throws {
        let parsed = AnthropicResetParser.parse(try fixture("anthropic-resets-ineligible"))
        XCTAssertNil(parsed.count)
        XCTAssertNil(parsed.selectedGrantID, "an ineligible account has nothing to spend, whatever next_grant_id says")
    }

    func testEligibleWithNoGrantsYieldsZero() throws {
        XCTAssertEqual(AnthropicResetParser.parse(try fixture("anthropic-resets-no-grants")).count, 0)
        XCTAssertEqual(grants(#"{"cedar_ember":{"eligible":true}}"#).count, 0, "grants absent")
        XCTAssertEqual(grants(#"{"cedar_ember":{"eligible":true,"grants":null}}"#).count, 0, "grants null")
    }

    func testEligibleWithGrantsAllAtZeroYieldsZero() {
        let parsed = grants(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"grant_test_a","resets_left":0,"usable_now":true},{"id":"grant_test_b","resets_left":0}]}}"#)
        XCTAssertEqual(parsed.count, 0)
        XCTAssertNil(parsed.selectedGrantID, "a grant with nothing left is never spent")
    }

    /// No block at all parses exactly as before: no count, same windows.
    func testExistingFixturesHaveNoCount() throws {
        for name in ["anthropic-limits", "anthropic-legacy", "anthropic-inactive"] {
            XCTAssertEqual(AnthropicResetParser.parse(try fixture(name)), .absent, name)
        }
        XCTAssertEqual(grants(#"{"cedar_ember":null}"#), .absent)
        XCTAssertEqual(grants("not json"), .absent)
        XCTAssertEqual(grants("[]"), .absent)
    }

    /// Every malformed shape leaves the windows exactly as the clean fixture's
    /// and yields no count, because no valid grant is left.
    func testMalformedBlocksNeverBreakTheWindows() throws {
        let clean = try AnthropicUsageParser.parse(try fixture("anthropic-limits"))
        let shapes = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture("anthropic-resets-malformed-blocks")) as? [String: Any])
        XCTAssertGreaterThanOrEqual(shapes.count, 10)
        for (name, block) in shapes {
            let body = try cleanBody(withBlock: block)
            XCTAssertEqual(try AnthropicUsageParser.parse(body), clean, name)
            let parsed = AnthropicResetParser.parse(body)
            XCTAssertNil(parsed.count, name)
            XCTAssertNil(parsed.selectedGrantID, name)
        }
    }

    /// Malformed grants are skipped; the valid ones still count.
    func testMalformedGrantsAreSkipped() {
        let parsed = grants(#"""
        {"cedar_ember":{"eligible":true,"grants":[
          "grant_bad_string",
          {"id":"Grant_Upper","resets_left":5,"usable_now":true},
          {"id":"grant_test_neg","resets_left":-2,"usable_now":true},
          {"id":"grant_test_frac","resets_left":0.5,"usable_now":true},
          {"id":"grant_test_ok","resets_left":2,"usable_now":true}
        ]}}
        """#)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.selectedGrantID, "grant_test_ok")
    }

    // MARK: Grant selection

    private let selectionGrants = #"""
      [{"id":"grant_late","resets_left":1,"usable_now":true,"ends_at":"2026-09-01T00:00:00Z"},
       {"id":"grant_soon","resets_left":1,"usable_now":true,"ends_at":"2026-08-01T00:00:00Z"},
       {"id":"grant_sooner_unusable","resets_left":1,"usable_now":false,"ends_at":"2026-07-15T00:00:00Z"},
       {"id":"grant_sooner_empty","resets_left":0,"usable_now":true,"ends_at":"2026-07-14T00:00:00Z"}]
    """#

    func testSelectionUsesAValidNextGrantID() {
        let parsed = grants(#"{"cedar_ember":{"eligible":true,"next_grant_id":"grant_late","grants":\#(selectionGrants)}}"#)
        XCTAssertEqual(parsed.selectedGrantID, "grant_late")
    }

    func testSelectionFallsBackWhenNextGrantIDNamesAMissingGrant() {
        let parsed = grants(#"{"cedar_ember":{"eligible":true,"next_grant_id":"grant_gone","grants":\#(selectionGrants)}}"#)
        XCTAssertEqual(parsed.selectedGrantID, "grant_soon", "the usable grant that ends soonest")
    }

    func testSelectionFallsBackWhenNextGrantIDIsNull() {
        let parsed = grants(#"{"cedar_ember":{"eligible":true,"next_grant_id":null,"grants":\#(selectionGrants)}}"#)
        XCTAssertEqual(parsed.selectedGrantID, "grant_soon")
        XCTAssertEqual(parsed.count, 3)
    }

    func testSelectionIgnoresAnInvalidNextGrantIDAndPrefersGrantsWithAnEnd() {
        let parsed = grants(#"""
        {"cedar_ember":{"eligible":true,"next_grant_id":"GRANT/../x","grants":[
          {"id":"grant_no_end","resets_left":1,"usable_now":true},
          {"id":"grant_with_end","resets_left":1,"usable_now":true,"ends_at":"2026-12-01T00:00:00Z"}]}}
        """#)
        XCTAssertEqual(parsed.selectedGrantID, "grant_with_end")
    }

    /// The four selection rules, in order: a valid `next_grant_id`; else the
    /// usable grant ending soonest; else any grant with resets left ending
    /// soonest; else none.
    func testSelectionRulesInOrder() {
        let cases: [(String, String, String?)] = [
            ("next_grant_id wins", #"{"eligible":true,"next_grant_id":"grant_late","grants":\#(selectionGrants)}"#, "grant_late"),
            ("usable soonest", #"{"eligible":true,"grants":\#(selectionGrants)}"#, "grant_soon"),
            ("non-usable fallback, soonest", #"""
             {"eligible":true,"grants":[
               {"id":"grant_idle_late","resets_left":1,"usable_now":false,"ends_at":"2026-09-01T00:00:00Z"},
               {"id":"grant_idle_soon","resets_left":2,"ends_at":"2026-08-01T00:00:00Z"},
               {"id":"grant_empty_sooner","resets_left":0,"usable_now":true,"ends_at":"2026-07-14T00:00:00Z"}]}
             """#, "grant_idle_soon"),
            ("no resets left anywhere", #"{"eligible":true,"grants":[{"id":"grant_a","resets_left":0,"usable_now":true},{"id":"grant_b","resets_left":0}]}"#, nil),
        ]
        for (name, block, expected) in cases {
            let parsed = grants(#"{"cedar_ember":\#(block)}"#)
            XCTAssertEqual(parsed.selectedGrantID, expected, name)
        }
    }

    /// Whenever the count is above zero there is a grant to send, so the row
    /// and the button never disagree.
    func testPositiveCountAlwaysHasASelection() {
        let parsed = grants(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"grant_idle","resets_left":3,"usable_now":false}]}}"#)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.selectedGrantID, "grant_idle")
    }

    func testTwoGrantFixtureSelectsTheSoonestEnding() throws {
        XCTAssertEqual(AnthropicResetParser.parse(try fixture("anthropic-resets-two-grants")).selectedGrantID, "grant_test_b")
    }

    // MARK: Reset answers

    private let now = Date.iso("2026-07-13T12:00:00Z")

    private func outcome(_ json: String) -> ResetOutcome {
        AnthropicResetParser.outcome(Data(json.utf8), now: now)
    }

    func testResultMapping() {
        let table: [(String, ResetOutcome)] = [
            (#"{"result":"reset","resets_left":1,"cleared":["five_hour"]}"#, .reset),
            (#"{"result":"reset","reason":"stamp_indeterminate"}"#, .reset),
            (#"{"result":"already_used","reason":"already_used"}"#, .reset),
            (#"{"result":"not_limited","reason":"not_limited"}"#, .nothingToReset),
            (#"{"result":"ineligible","reason":"tier"}"#, .notAvailable),
            (#"{"result":"ineligible","reason":"config_off"}"#, .notAvailable),
            (#"{"result":"ineligible"}"#, .notAvailable),
            // Unavailable may have spent unless the reason says otherwise.
            (#"{"result":"unavailable"}"#, .unexpected),
            (#"{"result":"unavailable","reason":null}"#, .unexpected),
            (#"{"result":"unavailable","reason":"unknown"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"tier"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"no_grant"}"#, .noCredit),
            // The grant went stale: the re-read corrects the count.
            (#"{"result":"unavailable","reason":"not_next_grant"}"#, .notAvailable),
            (#"{"result":"ineligible","reason":"unknown_grant"}"#, .notAvailable),
            (#"{"result":"unavailable","reason":"paused"}"#, .notAvailable),
            (#"{"result":"unavailable","reason":"expired"}"#, .notAvailable),
            (#"{"result":"not_next_grant"}"#, .notAvailable),
            (#"{"result":"unknown_grant"}"#, .notAvailable),
            (#"{"result":"paused"}"#, .notAvailable),
            (#"{"result":"expired"}"#, .notAvailable),
            // Nothing to spend.
            (#"{"result":"ineligible","reason":"no_grant"}"#, .noCredit),
            (#"{"result":"no_grant"}"#, .noCredit),
            // Unknown whether it spent, or a request this build should not send.
            (#"{"result":"unavailable","reason":"stamp_indeterminate"}"#, .unexpected),
            (#"{"result":"unavailable","reason":"reset_unconfirmed"}"#, .unexpected),
            (#"{"result":"ineligible","reason":"grant_id_required"}"#, .unexpected),
            (#"{"result":"stamp_indeterminate"}"#, .unexpected),
            (#"{"result":"reset_unconfirmed"}"#, .unexpected),
            (#"{"result":"grant_id_required"}"#, .unexpected),
            // Not an answer this build knows.
            (#"{"result":"something_new"}"#, .unexpected),
            (#"{"result":"tier"}"#, .unexpected),
            (#"{"result":7}"#, .unexpected),
            (#"{}"#, .unexpected),
            ("[]", .unexpected),
            ("<html>", .unexpected),
        ]
        for (body, expected) in table {
            XCTAssertEqual(outcome(body), expected, body)
        }
    }

    func testCooldownKeepsOnlyAFutureTime() {
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":"2026-07-13T12:30:00Z"}"#), .cooldown(until: Date.iso("2026-07-13T12:30:00Z")))
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":"2026-07-13T11:00:00Z"}"#), .cooldown(until: nil), "a past time")
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":"soon"}"#), .cooldown(until: nil), "unreadable")
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":null}"#), .cooldown(until: nil))
        XCTAssertEqual(outcome(#"{"result":"cooldown"}"#), .cooldown(until: nil))
    }

    // MARK: Id rules

    func testIdRules() {
        XCTAssertTrue(AnthropicEndpoints.isValidGrantID("grant_test-a1"))
        XCTAssertFalse(AnthropicEndpoints.isValidGrantID(""))
        XCTAssertFalse(AnthropicEndpoints.isValidGrantID("Grant"))
        XCTAssertFalse(AnthropicEndpoints.isValidGrantID(String(repeating: "a", count: 41)))
        XCTAssertTrue(AnthropicEndpoints.isValidGrantID(String(repeating: "a", count: 40)))
        XCTAssertFalse(AnthropicEndpoints.isValidGrantID("gränt"))
        XCTAssertTrue(AnthropicEndpoints.isValidRequestID(UUID().uuidString.lowercased()))
        XCTAssertTrue(AnthropicEndpoints.isValidRequestID("Req_1-a"))
        XCTAssertFalse(AnthropicEndpoints.isValidRequestID(String(repeating: "a", count: 65)))
        XCTAssertFalse(AnthropicEndpoints.isValidRequestID("a b"))
        XCTAssertNil(AnthropicEndpoints.resetRateLimits(orgUUID: "../x"))
        XCTAssertNil(AnthropicEndpoints.resetRateLimits(orgUUID: ""))
    }
}
