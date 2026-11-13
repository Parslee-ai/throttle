import XCTest
@testable import Throttle

/// Reset kinds from the Claude reset block: one kind per kind present,
/// grouped by the kind rule, counted per kind, and judged spendable by every
/// flag, with a missing flag refusing.
final class AnthropicResetKindsTests: XCTestCase {
    private let now = Date.iso("2026-07-13T12:00:00Z")

    private func kindsFixture() throws -> Data {
        try AnthropicFixtures.data("anthropic-resets-kinds")
    }

    /// A block with these grants and account fields, on the clean windows.
    private func block(_ grants: String, fields: String = #""at_limit":false"#) -> AnthropicResetGrants {
        AnthropicResetParser.parse(Data(#"{"cedar_ember":{"eligible":true,\#(fields),"grants":[\#(grants)]}}"#.utf8))
    }

    /// A spendable grant of `kind` with the given fields replaced or added.
    private func grant(_ id: String, type: String = "full", extra: String = "") -> String {
        var fields = [
            #""id":"\#(id)""#, #""type":"\#(type)""#, #""resets_left":1"#,
            #""ends_at":"2026-08-01T00:00:00Z""#, #""paused":false"#,
            #""usable_now":true"#, #""use_requires_limit":false"#,
        ]
        if !extra.isEmpty { fields.append(extra) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func kinds(_ grants: AnthropicResetGrants, modelName: String? = nil) -> [ResetKind]? {
        grants.kinds(at: now, modelName: modelName)
    }

    // MARK: The kinds fixture

    func testTheKindsFixtureGivesAFullKindAndANamedModelRefill() throws {
        let body = try kindsFixture()
        let windows = try AnthropicUsageParser.parse(body)
        let parsed = AnthropicResetParser.parse(body)
        let found = try XCTUnwrap(kinds(parsed, modelName: AnthropicResetGrants.modelName(from: windows)))

        XCTAssertEqual(found.map(\.key), [.full, .modelRefill])
        XCTAssertEqual(found.map(\.count), [2, 2], "two full grants of one, one refill of two")
        XCTAssertEqual(found.map(\.label), ["Full reset", "Testmodel reset"])
        XCTAssertTrue(found.allSatisfy(\.isSpendable))
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(found.reduce(0) { $0 + $1.count }, parsed.count, "the total is the sum over kinds")
    }

    func testTheKindRule() {
        XCTAssertEqual(AnthropicResetParser.kind(type: "full", givesBackWeekly: false), .full)
        XCTAssertEqual(AnthropicResetParser.kind(type: "weekly", givesBackWeekly: false), .weekly)
        XCTAssertEqual(AnthropicResetParser.kind(type: "session", givesBackWeekly: false), .session)
        XCTAssertEqual(AnthropicResetParser.kind(type: "weekly", givesBackWeekly: true), .modelRefill)
        XCTAssertEqual(AnthropicResetParser.kind(type: "full", givesBackWeekly: true), .modelRefill, "giving back wins over the type")
        XCTAssertEqual(AnthropicResetParser.kind(type: "seasonal", givesBackWeekly: false), .other)
        XCTAssertEqual(AnthropicResetParser.kind(type: nil, givesBackWeekly: false), .other)
        XCTAssertEqual(AnthropicResetParser.kind(type: 7, givesBackWeekly: false), .other)
    }

    /// A kind with a reset left that cannot be spent still counts, so the
    /// row shows what the account holds and why it cannot use it.
    func testABlockedKindStillCounts() throws {
        let parsed = block(grant("grant_a").replacingOccurrences(of: #""paused":false"#, with: #""paused":true"#))
        let only = try XCTUnwrap(kinds(parsed)?.first)
        XCTAssertEqual(only.count, 1)
        XCTAssertEqual(only.reason, .paused)
        XCTAssertEqual(parsed.count, 1)
    }

    /// A grant counts while `ends_at` is after now and not at or past it.
    func testExpiryIsJudgedByTheClock() throws {
        let edge = block(grant("grant_a").replacingOccurrences(of: "2026-08-01T00:00:00Z", with: "2026-07-13T12:00:00Z"))
        XCTAssertNil(kinds(edge), "ending exactly now is expired")
        let justBefore = edge.kinds(at: now.addingTimeInterval(-1), modelName: nil)
        XCTAssertEqual(justBefore?.first?.count, 1)
    }

    // MARK: Spendable, and why not

    func testMissingFlagsRefuse() throws {
        let bare = block(#"{"id":"grant_a","type":"full","resets_left":1,"ends_at":"2026-08-01T00:00:00Z"}"#)
        XCTAssertEqual(kinds(bare)?.first?.reason, .notUsableNow, "usable_now absent is false")

        let noLimitFlag = block(#"{"id":"grant_a","type":"full","resets_left":1,"usable_now":true}"#)
        XCTAssertEqual(kinds(noLimitFlag)?.first?.reason, .usableOnlyAtLimit, "use_requires_limit absent is true")

        let nulls = block(#"{"id":"grant_a","type":"full","resets_left":1,"usable_now":null,"use_requires_limit":null}"#)
        XCTAssertEqual(kinds(nulls)?.first?.reason, .notUsableNow, "null is absent")

        let needsLimit = grant("grant_a").replacingOccurrences(of: #""use_requires_limit":false"#, with: #""use_requires_limit":true"#)
        let noAtLimit = block(needsLimit, fields: #""next_grant_id":null"#)
        XCTAssertEqual(kinds(noAtLimit)?.first?.reason, .usableOnlyAtLimit, "at_limit absent is false")
    }

    func testAGrantThatNeedsALimitIsSpendableAtOne() throws {
        let needsLimit = grant("grant_a").replacingOccurrences(of: #""use_requires_limit":false"#, with: #""use_requires_limit":true"#)
        XCTAssertEqual(kinds(block(needsLimit))?.first?.reason, .usableOnlyAtLimit)
        XCTAssertNil(kinds(block(needsLimit, fields: #""at_limit":true"#))?.first?.reason)
    }

    func testEachReasonWhenNothingIsSpendable() throws {
        let cases: [(String, String, ResetKind.Reason)] = [
            ("none left", grant("grant_a").replacingOccurrences(of: #""resets_left":1"#, with: #""resets_left":0"#), .noneLeft),
            ("not started", grant("grant_a", extra: #""starts_at":"2026-07-14T00:00:00Z""#), .notStarted(startsAt: Date.iso("2026-07-14T00:00:00Z"))),
            ("paused", grant("grant_a").replacingOccurrences(of: #""paused":false"#, with: #""paused":true"#), .paused),
            ("not usable", grant("grant_a").replacingOccurrences(of: #""usable_now":true"#, with: #""usable_now":false"#), .notUsableNow),
        ]
        for (name, body, reason) in cases {
            XCTAssertEqual(kinds(block(body))?.first?.reason, reason, name)
        }
        let cooling = block(grant("grant_a"), fields: #""at_limit":false,"cooldown_until":"2026-07-13T13:00:00Z""#)
        XCTAssertEqual(kinds(cooling)?.first?.reason, .cooldown(until: Date.iso("2026-07-13T13:00:00Z")))
        let refill = grant("grant_r", type: "weekly", extra: #""gives_back_weekly":true,"percent_used":{"m":0}"#)
        XCTAssertEqual(kinds(block(refill))?.first?.reason, .nothingToGiveBack)
    }

    /// The cooldown outranks everything, and among blocked grants the reason
    /// nearest to being spendable is shown: the earliest start wins.
    func testReasonOrder() throws {
        let paused = grant("grant_a").replacingOccurrences(of: #""paused":false"#, with: #""paused":true"#)
        let later = grant("grant_b", extra: #""starts_at":"2026-07-15T00:00:00Z""#)
        let sooner = grant("grant_c", extra: #""starts_at":"2026-07-14T00:00:00Z""#)
        XCTAssertEqual(kinds(block([paused, later, sooner].joined(separator: ",")))?.first?.reason,
                       .notStarted(startsAt: Date.iso("2026-07-14T00:00:00Z")))
        let cooling = block([paused, later].joined(separator: ","), fields: #""at_limit":false,"cooldown_until":"2026-07-13T13:00:00Z""#)
        XCTAssertEqual(kinds(cooling)?.first?.reason, .cooldown(until: Date.iso("2026-07-13T13:00:00Z")))
        XCTAssertNil(kinds(block([paused, grant("grant_d")].joined(separator: ",")))?.first?.reason, "one spendable grant is enough")
    }

    /// The usage figures block a refill only when every one is a number at 0.
    func testModelRefillUsageIsUnknownUnlessEveryFigureIsZero() {
        XCTAssertTrue(AnthropicResetParser.allUsageIsZero(["a": 0, "b": 0.0]))
        XCTAssertFalse(AnthropicResetParser.allUsageIsZero(["a": 0, "b": 1]))
        XCTAssertFalse(AnthropicResetParser.allUsageIsZero([String: Any]()), "empty is unknown")
        XCTAssertFalse(AnthropicResetParser.allUsageIsZero(nil), "missing is unknown")
        XCTAssertFalse(AnthropicResetParser.allUsageIsZero(["a": 0, "b": "0"]), "partly unreadable is unknown")
        XCTAssertFalse(AnthropicResetParser.allUsageIsZero(["a": false]), "a boolean is not a figure")
    }

    // MARK: The model refill's name

    func testTheRefillIsNamedForTheOneModelScopedWeeklyWindow() throws {
        let one = [UsageWindow(key: UsageWindow.scopedPrefix + "Testmodel", label: "Testmodel", usedPercent: 1, resetsAt: nil, durationSeconds: AnthropicUsageParser.weeklySeconds)]
        XCTAssertEqual(AnthropicResetGrants.modelName(from: one), "Testmodel")
        let two = one + [UsageWindow(key: UsageWindow.scopedPrefix + "Othermodel", label: "Othermodel", usedPercent: 1, resetsAt: nil, durationSeconds: AnthropicUsageParser.weeklySeconds)]
        XCTAssertNil(AnthropicResetGrants.modelName(from: two))
        XCTAssertNil(AnthropicResetGrants.modelName(from: []))
        XCTAssertEqual(AnthropicResetGrants.label(for: .modelRefill, modelName: nil), "Model reset")
    }

    func testALongOrHostileModelNameIsCleanedAndFits() {
        let hostile = String(repeating: "Model\nname\u{0007} ", count: 20) + "Bearer " + FakeToken.anthropicSecret
        let label = AnthropicResetGrants.label(for: .modelRefill, modelName: hostile)
        XCTAssertLessThanOrEqual(label.count, ResetKind.maxLabelLength)
        XCTAssertTrue(label.hasSuffix(" reset"))
        XCTAssertFalse(label.contains("\n"))
        XCTAssertFalse(label.contains(FakeToken.anthropicSecret))
    }

    // MARK: Bad grants

    func testOneBadGrantIsSkippedAndTheRestCount() throws {
        let parsed = block([grant("grant_a"), #"{"id":"Bad Id","resets_left":1}"#, grant("grant_b", type: "weekly")].joined(separator: ","))
        XCTAssertEqual(kinds(parsed)?.map(\.key), [.full, .weekly])
        XCTAssertEqual(parsed.count, 2)
    }

    func testMalformedGrantShapesAreEachSkipped() {
        let shapes = [
            #""text""#, "7", "null", #"{"resets_left":1}"#,
            #"{"id":"grant_x","resets_left":-1}"#, #"{"id":"grant_x","resets_left":1.5}"#,
            #"{"id":"grant_x","resets_left":"1"}"#, #"{"id":"grant_x","resets_left":2,"resets_total":1}"#,
            #"{"id":"grant_x","resets_left":1,"paused":"no"}"#, #"{"id":"grant_x","resets_left":1,"ends_at":"soon"}"#,
        ]
        for shape in shapes {
            let parsed = block([grant("grant_a"), shape].joined(separator: ","))
            XCTAssertEqual(parsed.count, 1, shape)
            XCTAssertEqual(parsed.grants.map(\.id), ["grant_a"], shape)
        }
    }

    func testAnAbsentTotalIsAllowed() {
        XCTAssertEqual(block(grant("grant_a")).grants.first?.resetsTotal, nil)
    }

    func testADuplicatedIdDropsEveryCopy() {
        let parsed = block([grant("grant_a"), grant("grant_a", type: "weekly"), grant("grant_b")].joined(separator: ","))
        XCTAssertEqual(parsed.grants.map(\.id), ["grant_b"])
        XCTAssertEqual(parsed.count, 1)
    }

    /// The grant's own label and the list of windows it clears are never read:
    /// labels come from the kind, so a hostile label never reaches the row.
    func testTheGrantsLabelAndClearedListAreIgnored() throws {
        let parsed = block(grant("grant_a", extra: #""label":"Bearer \#(FakeToken.anthropicSecret)","clears":"not a list""#))
        XCTAssertEqual(kinds(parsed)?.first?.label, "Full reset")
    }

    /// Unreadable account-wide fields fail closed: nothing is spendable, and
    /// the windows are unharmed.
    func testUnreadableAccountFieldsFailClosed() throws {
        let badLimit = block(grant("grant_a").replacingOccurrences(of: #""use_requires_limit":false"#, with: #""use_requires_limit":true"#), fields: #""at_limit":"yes""#)
        XCTAssertEqual(kinds(badLimit)?.first?.reason, .notUsableNow)
        let badCooldown = block(grant("grant_a"), fields: #""at_limit":false,"cooldown_until":"later""#)
        XCTAssertEqual(kinds(badCooldown)?.first?.reason, .cooldown(until: nil))
    }

    func testABadBlockNeverHarmsTheWindows() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicFixtures.data("anthropic-limits")) as? [String: Any])
        root[AnthropicResetParser.blockKey] = ["eligible": true, "grants": [["id": "Bad Id"]], "at_limit": "x"]
        let body = try JSONSerialization.data(withJSONObject: root)
        XCTAssertEqual(try AnthropicUsageParser.parse(body), try AnthropicUsageParser.parse(try AnthropicFixtures.data("anthropic-limits")))
        XCTAssertNil(kinds(AnthropicResetParser.parse(body)))
    }

    // MARK: Eligibility

    func testIneligibleOrEmptyYieldsNoKinds() throws {
        let ineligible = AnthropicResetParser.parse(try AnthropicFixtures.data("anthropic-resets-ineligible"))
        XCTAssertNil(kinds(ineligible))
        XCTAssertNil(ineligible.count)
        let empty = AnthropicResetParser.parse(try AnthropicFixtures.data("anthropic-resets-no-grants"))
        XCTAssertNil(kinds(empty))
        XCTAssertEqual(empty.count, 0)
    }

    func testTheIneligibleReasonIsKeptOnlyFromTheKnownList() {
        let known = AnthropicResetParser.parse(Data(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"tier"}}"#.utf8))
        XCTAssertEqual(known.ineligibleReason, "tier")
        let unknown = AnthropicResetParser.parse(Data(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"user@example.com"}}"#.utf8))
        XCTAssertEqual(unknown.ineligibleReason, "unknown")
        let missing = AnthropicResetParser.parse(Data(#"{"cedar_ember":{"eligible":false}}"#.utf8))
        XCTAssertEqual(missing.ineligibleReason, "unknown")
    }

    func testAnEligibleBlockWithNoValidGrantNamesItsRule() {
        XCTAssertEqual(block(#"{"id":"Bad Id","resets_left":1}"#).noCountRule, AnthropicResetParser.Grant.Rule.id.rawValue)
        XCTAssertEqual(AnthropicResetParser.parse(Data(#"{"cedar_ember":{"eligible":true,"grants":{}}}"#.utf8)).noCountRule, "grants is not a list")
        XCTAssertNil(block(grant("grant_a")).noCountRule)
    }

    // MARK: What crosses the seam

    /// The status carries kinds with no grant id: the fixture's marker id is
    /// absent from the encoded status and from every key's description.
    func testKindsCarryNoGrantID() async throws {
        let client = AnthropicMockHTTPClient(status: 200, body: try kindsFixture())
        client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-profile"))
        let account = Account(id: UUID(), provider: .anthropic, email: "user@example.com", sortIndex: 0)
        let credential = AccountCredential(accessToken: AnthropicSampleSecret.accessToken, scopes: ["user:profile", "user:inference"])
        let fixed = now
        let status = try await AnthropicProvider(client: client, now: { fixed }).fetchStatus(account: account, credential: credential)

        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(text.contains("grant-sentinel-1"), text)
        for kind in try XCTUnwrap(status.resetKinds) {
            XCTAssertFalse(String(describing: kind.key).contains("grant"))
            XCTAssertFalse(String(reflecting: kind).contains("grant-sentinel-1"))
        }
        XCTAssertEqual(status.resetCreditsAvailable, status.resetKinds?.reduce(0) { $0 + $1.count })
        XCTAssertEqual(status.resetKinds?.map(\.label), ["Full reset", "Testmodel reset"])
    }

    // MARK: Every Claude fixture (ISC-468, ISC-469)

    /// Every Claude usage payload in the test bundle, plus the kinds fixture
    /// with each malformed block in place of its own, so a fixture added
    /// later is covered without editing this list.
    private func everyClaudePayload() throws -> [(name: String, body: Data)] {
        let urls = Bundle(for: Self.self).urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var payloads: [(name: String, body: Data)] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasPrefix("anthropic-") {
            let body = try Data(contentsOf: url)
            guard (try? AnthropicUsageParser.parse(body)) != nil else { continue }
            payloads.append((url.lastPathComponent, body))
        }
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try AnthropicFixtures.data("anthropic-resets-malformed-blocks")) as? [String: Any])
        for (name, block) in blocks.sorted(by: { $0.key < $1.key }) {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try kindsFixture()) as? [String: Any])
            root[AnthropicResetParser.blockKey] = block
            payloads.append(("malformed \(name)", try JSONSerialization.data(withJSONObject: root)))
        }
        let names = Set(payloads.map(\.name))
        for expected in ["anthropic-resets-kinds.json", "anthropic-resets-two-grants.json",
                         "anthropic-resets-no-grants.json", "anthropic-resets-ineligible.json", "anthropic-limits.json"] {
            XCTAssertTrue(names.contains(expected), "\(expected) was found: \(names.sorted())")
        }
        return payloads
    }

    /// One status read through the adapter, as a poll reads it.
    private func status(of body: Data, provider: AnthropicProvider, account: Account) async throws -> AccountStatus {
        let credential = AccountCredential(accessToken: AnthropicSampleSecret.accessToken, scopes: ["user:profile", "user:inference"])
        return try await provider.fetchStatus(account: account, credential: credential)
    }

    func testTotalIsTheSumOfKindCountsForEveryClaudeFixture() async throws {
        for (name, body) in try everyClaudePayload() {
            let client = AnthropicMockHTTPClient(status: 200, body: body)
            client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-profile"))
            let fixed = now
            let account = Account(id: UUID(), provider: .anthropic, email: "fixture-sum", sortIndex: 0)
            let status = try await status(of: body, provider: AnthropicProvider(client: client, now: { fixed }), account: account)

            if AnthropicResetParser.parse(body).count == nil {
                XCTAssertNil(status.resetCreditsAvailable, name)
                XCTAssertNil(status.resetKinds, name)
            } else {
                XCTAssertEqual(status.resetCreditsAvailable, (status.resetKinds ?? []).reduce(0) { $0 + $1.count }, name)
            }
        }
    }

    func testTwoReadsOfOnePayloadGiveEqualStatusesForEveryClaudeFixture() async throws {
        for (name, body) in try everyClaudePayload() {
            let client = AnthropicMockHTTPClient(status: 200, body: body)
            client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-profile"))
            client.enqueue(status: 200, body: body)
            client.enqueue(status: 200, body: try AnthropicFixtures.data("anthropic-profile"))
            let fixed = now
            let provider = AnthropicProvider(client: client, now: { fixed })
            let account = Account(id: UUID(), provider: .anthropic, email: "fixture-equal", sortIndex: 0)

            let first = try await status(of: body, provider: provider, account: account)
            let second = try await status(of: body, provider: provider, account: account)
            XCTAssertEqual(first, second, name)
            XCTAssertEqual(first.hashValue, second.hashValue, name)
        }
    }
}
