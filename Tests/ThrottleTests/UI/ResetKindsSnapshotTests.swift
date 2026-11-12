import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// Reset kinds on a Claude row, rendered by the same harness as the rest of
/// the detail window. Every fixture uses invented accounts.
extension PopupSnapshotTests {
    // MARK: Fixtures

    static let kindsNow = UIFixtures.now

    func kindsClaudeWindows(weekly: Double = 40, model: Double = 70, modelName: String = "Fable") -> [UsageWindow] {
        [
            UIFixtures.window("7d", label: "Weekly", used: weekly, resetsIn: 3 * 86_400, seconds: 604_800),
            UIFixtures.window(UsageWindow.scopedPrefix + modelName, label: modelName, used: model, resetsIn: 3 * 86_400, seconds: 604_800),
        ]
    }

    /// One account and its reading, `resetKinds` passed through as given.
    func kindsRow(
        _ email: String,
        provider: Provider = .anthropic,
        windows: [UsageWindow]? = nil,
        credits: Int? = nil,
        kinds: [ResetKind]? = nil,
        isStale: Bool = false
    ) -> (Account, CachedStatus) {
        let account = UIFixtures.account(email, provider: provider)
        let cached = UIFixtures.cached(
            for: account,
            windows: windows ?? (provider == .anthropic ? kindsClaudeWindows()
                : [UIFixtures.window("7d", label: "Weekly", used: 60, resetsIn: 2 * 86_400, seconds: 604_800)]),
            isStale: isStale,
            fetchedAt: isStale ? Self.kindsNow.addingTimeInterval(-15 * 60) : Self.kindsNow,
            planLabel: provider == .anthropic ? "max" : "pro",
            resetCreditsAvailable: credits,
            resetKinds: kinds
        )
        return (account, cached)
    }

    /// Rows in one list, as the detail window draws them.
    func kindsPanel(
        _ rows: [(Account, CachedStatus)],
        resetsInFlight: Set<UUID> = [],
        notices: [UUID: ResetNotice] = [:],
        gates: [UUID: ResetGate] = [:]
    ) -> some View {
        AccountsPanel(
            accounts: rows.map(\.0),
            statuses: Dictionary(uniqueKeysWithValues: rows.map { ($0.0.id, $0.1) }),
            planLabels: Dictionary(uniqueKeysWithValues: rows.map { ($0.0.id, $0.1.status.planLabel ?? "pro") }),
            now: Self.kindsNow,
            resetsInFlight: resetsInFlight,
            resetNotices: notices,
            resetGates: gates
        )
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
    }

    func renderBoth<V: View>(_ view: V, named name: String) throws {
        for appearance in Self.appearances {
            try check(try render(view, appearance: appearance.value), named: "\(name)-\(appearance.name)")
        }
    }

    // MARK: What stays as it is (ISC-421, ISC-422, ISC-400)

    /// Rows whose drawing this work must not change. Rendered once before
    /// any change and once after, and the PNGs compared byte for byte.
    func testRowsWithoutKindsRender() throws {
        let codex = kindsRow("codex-count@example.com", provider: .openai, credits: 2)
        try renderBoth(kindsPanel([codex]), named: "codex-with-count")
        let noResets = kindsRow("claude-plain@example.com")
        try renderBoth(kindsPanel([noResets]), named: "claude-no-resets")
        let claudeCount = kindsRow("claude-count@example.com", credits: 1)
        try renderBoth(kindsPanel([claudeCount]), named: "reset-claude-enabled")
        let claudeZero = kindsRow("claude-zero@example.com", credits: 0)
        try renderBoth(kindsPanel([claudeZero]), named: "reset-greyed-zero")
        let confirm = ResetConfirmation(
            displayName: codex.0.displayName,
            count: 2,
            windows: Formatting.windowOrder(Formatting.windows(of: codex.1)),
            onConfirm: {},
            onCancel: {}
        )
        .background(Colors.windowBackground)
        try renderBoth(confirm, named: "codex-confirm")
    }

    // MARK: Kind fixtures

    func full(_ count: Int, _ reason: ResetKind.Reason? = nil) -> ResetKind {
        ResetKind(key: .full, label: "Full reset", count: count, reason: reason)
    }

    func refill(_ count: Int, _ reason: ResetKind.Reason? = nil, model: String = "Fable") -> ResetKind {
        ResetKind(key: .modelRefill, label: "\(model) reset", count: count, reason: reason)
    }

    func weeklyKind(_ count: Int, _ reason: ResetKind.Reason? = nil) -> ResetKind {
        ResetKind(key: .weekly, label: "7-day reset", count: count, reason: reason)
    }

    func sessionKind(_ count: Int, _ reason: ResetKind.Reason? = nil) -> ResetKind {
        ResetKind(key: .session, label: "5-hour reset", count: count, reason: reason)
    }

    func plainKind(_ count: Int, _ reason: ResetKind.Reason? = nil) -> ResetKind {
        ResetKind(key: .other, label: "", count: count, reason: reason)
    }

    /// Writes the tooltips a snapshot cannot show, beside its PNG.
    func recordHelp(_ lines: [String], named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["THROTTLE_SNAPSHOT_DIR"], !directory.isEmpty else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(name)-help.txt"), atomically: true, encoding: .utf8)
    }

    /// Each line's tooltip and the button's, as the row draws them.
    func helpLines(_ row: (Account, CachedStatus), gate: ResetGate? = nil) -> [String] {
        let offer = ResetOffer(
            count: row.1.status.resetCreditsAvailable ?? 0,
            kinds: row.1.status.resetKinds,
            dimmed: AccountRow.isDimmed(row.1),
            gate: gate,
            now: Self.kindsNow
        )
        let lines = offer.kinds.map { "\($0.count)  \($0.label): \(offer.reason(for: $0) ?? "(spendable; tooltip is the label)")" }
        return ["\(row.0.email)"] + lines.map { "  " + $0 } + ["  Use reset button: \(offer.disabledReason.map { "greyed — \($0)" } ?? "enabled — \(offer.enabledHelp)")"]
    }

    func confirmation(
        _ row: (Account, CachedStatus),
        gate: ResetGate? = nil,
        picked: ResetKind.Key? = nil
    ) -> some View {
        ResetConfirmation(
            displayName: row.0.displayName,
            count: row.1.status.resetCreditsAvailable ?? 0,
            windows: Formatting.windowOrder(Formatting.windows(of: row.1)),
            kinds: row.1.status.resetKinds,
            gate: gate,
            now: Self.kindsNow,
            picked: picked,
            onChoice: { _ in },
            onCancel: {}
        )
        .background(Colors.windowBackground)
    }

    // MARK: The row (ISC-394 to ISC-404)

    func testKindRowsRender() throws {
        let two = kindsRow("two-kinds@example.com", kinds: [full(2), refill(1)])
        try renderBoth(kindsPanel([two]), named: "kinds-row-two-kinds")
        let one = kindsRow("one-kind@example.com", kinds: [full(2)])
        try renderBoth(kindsPanel([one]), named: "kinds-row-one-kind")
        let three = kindsRow("three-kinds@example.com", kinds: [full(2), weeklyKind(1), refill(1)])
        try renderBoth(kindsPanel([three]), named: "kinds-row-three-kinds")
        let summed = kindsRow("summed@example.com", kinds: [full(2), full(1), refill(1)])
        XCTAssertEqual(ResetOffer(count: 4, kinds: summed.1.status.resetKinds, dimmed: false, gate: nil, now: Self.kindsNow).kinds.map(\.count), [3, 1])
        try renderBoth(kindsPanel([summed]), named: "kinds-row-summed")
        // Out of order on purpose: the status puts them in the fixed order.
        let all = kindsRow("all-kinds@example.com", kinds: [plainKind(1), refill(1), sessionKind(1), weeklyKind(2), full(1)])
        XCTAssertEqual(all.1.status.resetKinds?.map(\.key), [.full, .weekly, .session, .modelRefill, .other])
        try renderBoth(kindsPanel([all]), named: "kinds-row-all-kinds")
        try renderBoth(confirmation(all), named: "kinds-confirm-all-kinds")
    }

    func testBlockedKindsRender() throws {
        let soon = Self.kindsNow.addingTimeInterval(2 * 3_600)
        let later = Self.kindsNow.addingTimeInterval(3 * 86_400)
        let a = kindsRow("blocked-a@example.com", kinds: [
            full(1, .usableOnlyAtLimit), weeklyKind(1, .paused), sessionKind(1, .notStarted(startsAt: later)),
            refill(1, .nothingToGiveBack), plainKind(1, .cooldown(until: soon)),
        ])
        let b = kindsRow("blocked-b@example.com", kinds: [full(1, .notUsableNow), refill(1)])
        try renderBoth(kindsPanel([a, b]), named: "kinds-blocked-reasons")
        try recordHelp(helpLines(a) + helpLines(b), named: "kinds-blocked-reasons")

        let noneLeft = kindsRow("none-left@example.com", kinds: [full(0), refill(1)])
        try renderBoth(kindsPanel([noneLeft]), named: "kinds-none-left")
        try recordHelp(helpLines(noneLeft), named: "kinds-none-left")

        // Eligible with no grant: no kinds and a count of 0, drawn exactly as
        // before kinds (compared with the baseline's reset-greyed-zero).
        let noGrants = kindsRow("claude-zero@example.com", credits: 0, kinds: [])
        try renderBoth(kindsPanel([noGrants]), named: "kinds-no-grants")
    }

    func testUseResetButtonStatesRender() throws {
        let enabled = kindsRow("button-enabled@example.com", kinds: [full(1, .paused), refill(1)])
        let retry = kindsRow("button-retry@example.com", kinds: [full(0), refill(1, .paused)])
        let retryGate = ResetGate.retryOnly(kind: .full, label: "Full reset")
        let oneBlocked = kindsRow("button-one-blocked@example.com", kinds: [refill(1, .usableOnlyAtLimit)])
        let allBlocked = kindsRow("button-all-blocked@example.com", kinds: [full(1, .paused), refill(1, .notUsableNow)])
        let allZero = kindsRow("button-all-zero@example.com", kinds: [full(0), refill(0)])
        let cases: [(String, (Account, CachedStatus), ResetGate?)] = [
            ("kinds-button-enabled", enabled, nil),
            ("kinds-button-retry-pending", retry, retryGate),
            ("kinds-button-one-kind-blocked", oneBlocked, nil),
            ("kinds-button-all-blocked", allBlocked, nil),
            ("kinds-button-all-zero", allZero, nil),
        ]
        for (name, row, gate) in cases {
            try renderBoth(kindsPanel([row], gates: gate.map { [row.0.id: $0] } ?? [:]), named: name)
            try recordHelp(helpLines(row, gate: gate), named: name)
        }

        let stale = kindsRow("stale-kinds@example.com", kinds: [full(2), refill(1)], isStale: true)
        try renderBoth(kindsPanel([stale]), named: "kinds-greyed-stale")
        try recordHelp(helpLines(stale), named: "kinds-greyed-stale")
    }

    func testOddKindNamesRender() throws {
        let long = kindsRow("long-name@example.com", kinds: [
            ResetKind(key: .modelRefill, label: "Extraordinarily Long Experimental Model Name reset", count: 1),
            ResetKind(key: .other, label: "Another very long unrecognized reset name here", count: 2),
        ])
        try renderBoth(kindsPanel([long]), named: "kinds-long-name")
        try recordHelp(helpLines(long), named: "kinds-long-name")
        let hostile = kindsRow("hostile-name@example.com", kinds: [
            ResetKind(key: .other, label: "Weird\nname\u{0007} Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", count: 1),
            full(1),
        ])
        let shown = hostile.1.status.resetKinds?.map(\.label) ?? []
        XCTAssertFalse(shown.contains { $0.contains("eyJ") || $0.contains("\n") }, "\(shown)")
        try renderBoth(kindsPanel([hostile]), named: "kinds-hostile-name")
        try recordHelp(helpLines(hostile), named: "kinds-hostile-name")
        let empty = kindsRow("empty-name@example.com", kinds: [ResetKind(key: .other, label: " \n\t ", count: 1)])
        XCTAssertEqual(empty.1.status.resetKinds?.first?.label, "Reset")
        try renderBoth(kindsPanel([empty]), named: "kinds-empty-name")
    }

    /// One kind costs no height; each further kind adds one line to that row
    /// only; the row never gets wider and the bars do not move.
    func testKindLinesAddOneLineEachAndMoveNothing() throws {
        let width = PopupMetrics.width
        let windows = kindsClaudeWindows()
        func height(_ row: (Account, CachedStatus)) -> CGFloat {
            fittedHeight(AccountRow(account: row.0, number: 1, cached: row.1, planLabel: "max", now: Self.kindsNow,
                                    isFirstInSection: true, isLastInSection: true), width: width)
        }
        let countOnly = height(kindsRow("h@example.com", windows: windows, credits: 1))
        let one = height(kindsRow("h@example.com", windows: windows, kinds: [full(2)]))
        let two = height(kindsRow("h@example.com", windows: windows, kinds: [full(2), refill(1)]))
        let three = height(kindsRow("h@example.com", windows: windows, kinds: [full(2), weeklyKind(1), refill(1)]))
        XCTAssertEqual(one, countOnly, "one kind is as tall as the count-only row")

        // In the column each further kind is one text line. The row grows by
        // at most that: the window columns beside a one-kind column are a
        // little taller than it, so the second line first fills that room.
        let columnHeight = fittedHeight(ResetCreditsColumn(count: 2, dimmed: false))
        XCTAssertEqual(fittedHeight(ResetCreditsColumn(count: 2, dimmed: false, kinds: [full(2)])), columnHeight)
        let line = fittedHeight(ResetCreditsColumn(count: 3, dimmed: false, kinds: [full(2), refill(1)])) - columnHeight
        XCTAssertGreaterThan(line, 14)
        XCTAssertLessThan(line, 22, "one text line")
        XCTAssertEqual(fittedHeight(ResetCreditsColumn(count: 4, dimmed: false, kinds: [full(2), weeklyKind(1), refill(1)])),
                       columnHeight + 2 * line, accuracy: 0.5)
        XCTAssertGreaterThan(two, one)
        XCTAssertLessThanOrEqual(two - one, line + 0.5)
        XCTAssertEqual(three - two, line, accuracy: 0.5)

        let light = NSAppearance(named: .aqua)!
        let a = try render(kindsPanel([kindsRow("bars@example.com", windows: windows, kinds: [full(2)])]), appearance: light)
        let b = try render(kindsPanel([kindsRow("bars@example.com", windows: windows, kinds: [full(2), weeklyKind(1), refill(1)])]), appearance: light)
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, "the row never gets wider")
        let scale = CGFloat(a.pixelsWide) / PopupMetrics.width
        let barsStart = Int(PopupMetrics.columnsLeading * scale)
        let barsEnd = Int((PopupMetrics.columnsLeading + 2 * PopupMetrics.columnWidth + PopupMetrics.columnGap) * scale)
        // The window columns' top: title, percentage, bar and reset line.
        let top = 0..<Int(70 * scale)
        XCTAssertTrue(Self.samePixels(a, b, columns: barsStart..<barsEnd, rows: top), "the bars do not move")
    }

    // MARK: Confirming (ISC-405 to ISC-410, ISC-417)

    func testKindConfirmationsRender() throws {
        let one = kindsRow("confirm-one@example.com", kinds: [full(2)])
        try renderBoth(confirmation(one), named: "kinds-confirm-one-kind")

        let several = kindsRow("confirm-several@example.com", kinds: [full(2), weeklyKind(1, .usableOnlyAtLimit), refill(1)])
        try renderBoth(confirmation(several), named: "kinds-confirm-unpicked")
        try renderBoth(confirmation(several, picked: .full), named: "kinds-confirm-picked")

        let quill = kindsRow("confirm-refill@example.com", windows: kindsClaudeWindows(modelName: "Quill"),
                             kinds: [full(1), refill(1, model: "Quill")])
        try renderBoth(confirmation(quill, picked: .modelRefill), named: "kinds-confirm-model-refill")

        let retryGate = ResetGate.retryOnly(kind: .full, label: "Full reset")
        let retry = kindsRow("confirm-retry@example.com", kinds: [full(1, .paused), refill(1)])
        try renderBoth(confirmation(retry, gate: retryGate), named: "kinds-confirm-retry-only")
        let retryGone = kindsRow("confirm-retry-gone@example.com", kinds: [refill(1)])
        try renderBoth(confirmation(retryGone, gate: retryGate), named: "kinds-confirm-retry-kind-gone")
        try renderBoth(kindsPanel([retry], gates: [retry.0.id: retryGate]), named: "kinds-retry-only-row")
        try recordHelp(helpLines(retry, gate: retryGate), named: "kinds-retry-only-row")
    }

    /// The owner picked Full reset; a reading that landed while the card was
    /// open no longer lists it. Confirming sends nothing and the row says so.
    func testChosenKindGoneAtConfirmRenders() throws {
        let before = kindsRow("kind-gone@example.com", kinds: [full(1), refill(1)])
        let after = kindsRow("kind-gone@example.com", kinds: [refill(1)])
        let choice = ResetConfirmation.Choice(kind: .full, label: "Full reset", retrying: false)
        let outcome = ResetConfirmation.outcome(of: choice, status: after.1.status, gate: nil)
        XCTAssertEqual(outcome, .hold(.noneLeft, label: "Full reset"))
        let notice = try XCTUnwrap(ResetConfirmation.heldNotice(for: outcome, providerName: "Claude", now: Self.kindsNow))
        XCTAssertEqual(notice.text, "No resets available")
        let row = (before.0, after.1)
        try renderBoth(kindsPanel([row], notices: [row.0.id: notice]), named: "kinds-confirm-kind-gone")
    }

    // MARK: Running, success and refusals (ISC-411 to ISC-418, ISC-518, ISC-524)

    private func notice(_ result: ResetResult, kind label: String? = nil) -> ResetNotice? {
        ResetMessages.notice(for: result, providerName: "Claude", now: Self.kindsNow, kindLabel: label)
    }

    func testKindResultsRender() throws {
        let running = kindsRow("running@example.com", kinds: [full(2), refill(1)])
        let idle = kindsRow("idle@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([running, idle], resetsInFlight: [running.0.id]), named: "kinds-running")

        let fullDone = kindsRow("success-full@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([fullDone], notices: [fullDone.0.id: notice(.outcome(.reset), kind: "Full reset")!]), named: "kinds-success-full")
        let plainDone = kindsRow("success-plain@example.com", kinds: [full(1), plainKind(0)])
        try renderBoth(kindsPanel([plainDone], notices: [plainDone.0.id: notice(.outcome(.reset), kind: "Reset")!]), named: "kinds-success-plain")

        // Full 2 → 1 and Fable 1 → 1, as the follow-up reading says.
        let fresh = kindsRow("success@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([fresh], notices: [fresh.0.id: notice(.outcome(.reset), kind: "Full reset")!]), named: "kinds-success")
        // The provider has not caught up: the row shows its 2, not 2 − 1.
        let lag = kindsRow("success-lag@example.com", kinds: [full(2), refill(1)])
        try renderBoth(kindsPanel([lag], notices: [lag.0.id: notice(.outcome(.reset), kind: "Full reset")!]), named: "kinds-success-server-lag")

        let last = kindsRow("success-last@example.com", kinds: [full(0), refill(0)])
        try renderBoth(kindsPanel([last], notices: [last.0.id: notice(.outcome(.reset), kind: "Fable reset")!]), named: "kinds-success-last")
        try recordHelp(helpLines(last), named: "kinds-success-last")

        let later = Self.kindsNow.addingTimeInterval(3_600)
        let refusals: [(String, ResetResult)] = [
            ("nothing-to-reset", .outcome(.nothingToReset)),
            ("cooldown", .outcome(.cooldown(until: later))),
            ("not-available", .outcome(.notAvailable)),
            ("rate-limited", .rateLimited(until: later)),
            ("unreachable", .unreachable),
            ("provider-error", .providerError(status: 503)),
            ("unexpected", .outcome(.unexpected)),
        ]
        for (name, result) in refusals {
            let row = kindsRow("refused-\(name)@example.com", kinds: [full(2), refill(1)])
            let shown = try XCTUnwrap(notice(result, kind: "Full reset"))
            XCTAssertEqual(shown.text, ResetMessages.notice(for: result, providerName: "Claude", now: Self.kindsNow)?.text,
                           "\(name): the same words as a row with no kinds")
            try renderBoth(kindsPanel([row], notices: [row.0.id: shown]), named: "kinds-refused-\(name)")
        }

        let waiting = kindsRow("waiting@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([waiting], notices: [waiting.0.id: notice(.outcome(.unexpected))!],
                                  gates: [waiting.0.id: .awaitingReading]), named: "kinds-waiting-fresh-reading")
        try recordHelp(helpLines(waiting, gate: .awaitingReading), named: "kinds-waiting-fresh-reading")

        // Saved numbers from before kinds: a count and no kinds yet.
        let saved = kindsRow("first-reading@example.com", credits: 2)
        try renderBoth(kindsPanel([saved], notices: [saved.0.id: notice(.outcome(.needsFreshReading))!]), named: "kinds-awaiting-first-reading")
        let read = kindsRow("first-reading@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([read]), named: "kinds-after-first-reading")

        let three = kindsRow("mixed-three@example.com", kinds: [full(2), weeklyKind(1), refill(1, .paused)])
        let busy = kindsRow("mixed-running@example.com", kinds: [full(1), refill(1)])
        let failed = kindsRow("mixed-failed@example.com", kinds: [full(1), refill(1)])
        try renderBoth(kindsPanel([three, busy, failed], resetsInFlight: [busy.0.id],
                                  notices: [failed.0.id: notice(.providerError(status: 503), kind: "Full reset")!]),
                       named: "kinds-three-rows-mixed")
    }

    /// After a model refill only the model's bar moves.
    func testModelRefillMovesOnlyItsBar() throws {
        let before = kindsRow("refill-bars@example.com", windows: kindsClaudeWindows(weekly: 40, model: 70), kinds: [full(1), refill(1)])
        let after = kindsRow("refill-bars@example.com", windows: kindsClaudeWindows(weekly: 40, model: 0), kinds: [full(1), refill(0)])
        try renderBoth(kindsPanel([before]), named: "kinds-success-model-refill-before")
        let done = kindsPanel([after], notices: [after.0.id: notice(.outcome(.reset), kind: "Fable reset")!])
        try renderBoth(done, named: "kinds-success-model-refill")

        let light = NSAppearance(named: .aqua)!
        let a = try render(kindsPanel([before]), appearance: light)
        let b = try render(done, appearance: light)
        let scale = CGFloat(a.pixelsWide) / PopupMetrics.width
        let weeklyColumn = Int(PopupMetrics.columnsLeading * scale)..<Int((PopupMetrics.columnsLeading + PopupMetrics.columnWidth) * scale)
        let modelColumn = Int((PopupMetrics.columnsLeading + PopupMetrics.columnWidth + PopupMetrics.columnGap) * scale)
            ..< Int((PopupMetrics.columnsLeading + 2 * PopupMetrics.columnWidth + PopupMetrics.columnGap) * scale)
        let top = 0..<Int(70 * scale)
        XCTAssertTrue(Self.samePixels(a, b, columns: weeklyColumn, rows: top), "the 7-day bar keeps its place")
        XCTAssertFalse(Self.samePixels(a, b, columns: modelColumn, rows: top), "the model's bar moved")
    }
}
