import AppKit
import SwiftUI
import XCTest
@testable import Throttle

/// Renders the detail window's account list and the menu bar label from
/// fixture data, once under a dark appearance and once under a light one.
///
/// The render is always checked for content. The PNGs are written only when
/// `THROTTLE_SNAPSHOT_DIR` is set (`TEST_RUNNER_THROTTLE_SNAPSHOT_DIR=…`
/// through xcodebuild), for a person to look at; they are not compared.
@MainActor
final class PopupSnapshotTests: XCTestCase {
    private let now = UIFixtures.now

    // MARK: Fixtures

    private struct Fixture {
        var accounts: [Account] = []
        var statuses: [UUID: CachedStatus] = [:]
        var plans: [UUID: String] = [:]

        mutating func add(
            _ email: String,
            provider: Provider,
            nickname: String? = nil,
            plan: String?,
            windows: [UsageWindow],
            state: AccountState = .ok,
            isStale: Bool = false,
            fetchedAt: Date = UIFixtures.now,
            resetCredits: Int? = nil
        ) {
            let account = UIFixtures.account(email, provider: provider, sortIndex: accounts.count, nickname: nickname)
            accounts.append(account)
            if let plan { plans[account.id] = plan }
            statuses[account.id] = UIFixtures.cached(
                for: account,
                windows: windows,
                state: state,
                isStale: isStale,
                fetchedAt: fetchedAt,
                planLabel: plan,
                resetCreditsAvailable: resetCredits
            )
        }
    }

    private func claudeWindows(fable: Double, session: Double, weekly: Double, resetsIn: TimeInterval?) -> [UsageWindow] {
        [
            UIFixtures.window("5h", label: "5h", used: session, resetsIn: nil, seconds: 18_000),
            UIFixtures.window("7d", label: "Weekly", used: weekly, resetsIn: resetsIn, seconds: 604_800),
            UIFixtures.window(UsageWindow.scopedPrefix + "Fable", label: "Fable", used: fable, resetsIn: resetsIn, seconds: 604_800),
        ]
    }

    private func weekly(_ used: Double, resetsIn: TimeInterval) -> [UsageWindow] {
        [UIFixtures.window("7d", label: "Weekly", used: used, resetsIn: resetsIn, seconds: 604_800)]
    }

    /// The reference layout: five Claude accounts and three Codex accounts,
    /// added in alternation so the grouping has work to do.
    private func referenceFixture() -> Fixture {
        var fixture = Fixture()
        let day: TimeInterval = 86_400
        fixture.add("claude-dev@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 0, session: 0, weekly: 0, resetsIn: 5 * day + 3600))
        fixture.add("codex-main@example.com", provider: .openai, plan: "pro",
                    windows: weekly(100, resetsIn: 1 * day + 4 * 3600), resetCredits: 1)
        fixture.add("team.lead@example.com", provider: .anthropic, nickname: "Work (team)", plan: "max",
                    windows: claudeWindows(fable: 21, session: 0, weekly: 11, resetsIn: 10 * 3600 + 30 * 60))
        fixture.add("codex-alt@example.com", provider: .openai, plan: "pro",
                    windows: weekly(15, resetsIn: 3 * day + 5 * 3600), resetCredits: 2)
        fixture.add("research@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 85, session: 40, weekly: 60, resetsIn: 1 * day + 2 * 3600))
        fixture.add("codex-ci-runner-with-a-long-address@example.com", provider: .openai, plan: "pro",
                    windows: weekly(2, resetsIn: 3 * day + 9 * 3600), resetCredits: 2)
        fixture.add("nightly@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 100, session: 55, weekly: 88, resetsIn: 4 * day + 12 * 3600))
        fixture.add("side-project@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 0, session: 0, weekly: 0, resetsIn: nil))
        return fixture
    }

    /// Rows in every non-ok state and a stale row.
    private func statesFixture() -> Fixture {
        var fixture = Fixture()
        fixture.add("stale@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 30, session: 10, weekly: 20, resetsIn: 2 * 86_400),
                    isStale: true, fetchedAt: now.addingTimeInterval(-12 * 60))
        // Dimmed with a window at 0%: the 0% must still read red.
        fixture.add("stale-empty@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 100, session: 85, weekly: 40, resetsIn: 3 * 86_400),
                    isStale: true, fetchedAt: now.addingTimeInterval(-15 * 60))
        fixture.add("signed-out@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 30, session: 10, weekly: 20, resetsIn: 86_400), state: .needsLogin)
        fixture.add("console@example.com", provider: .anthropic, plan: nil,
                    windows: [], state: .forbidden("OAuth authentication is currently not allowed for this organization."))
        fixture.add("throttled@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 5, session: 5, weekly: 5, resetsIn: 3 * 86_400),
                    state: .rateLimited(until: now.addingTimeInterval(3600)))
        fixture.add("broken@example.com", provider: .openai, plan: "pro", windows: [], state: .error("The request timed out."))
        fixture.add("errored-empty@example.com", provider: .openai, plan: "pro",
                    windows: weekly(100, resetsIn: 86_400), state: .error("The request timed out."),
                    isStale: true, resetCredits: 1)
        return fixture
    }

    /// More windows than fit on one line, and lanes.
    private func wrapFixture() -> Fixture {
        var fixture = Fixture()
        fixture.add("many-windows@example.com", provider: .anthropic, plan: "max_20x",
                    windows: claudeWindows(fable: 50, session: 20, weekly: 99.6, resetsIn: 6 * 86_400)
                        + [UIFixtures.window(UsageWindow.scopedPrefix + "Opus", label: "Opus", used: 81, resetsIn: 6 * 86_400, seconds: 604_800)])
        fixture.add("lanes@example.com", provider: .openai, plan: "pro",
                    windows: [
                        UIFixtures.window("5h", label: "5h", used: 12, resetsIn: 2 * 3600, seconds: 18_000),
                        UIFixtures.window("7d", label: "Weekly", used: 33, resetsIn: 5 * 86_400, seconds: 604_800),
                        UIFixtures.window("lane:Spark:5h", label: "Spark 5h", used: 0, resetsIn: 3600, seconds: 18_000),
                    ],
                    resetCredits: 0)
        return fixture
    }

    // MARK: Tests

    func testPopupRendersInDarkAndLight() throws {
        let fixture = referenceFixture()
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture), appearance: appearance.value)
            try check(image, named: "popup-\(appearance.name)")
        }
    }

    func testPopupStatesRenderInDarkAndLight() throws {
        let fixture = statesFixture()
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture), appearance: appearance.value)
            try check(image, named: "popup-states-\(appearance.name)")
        }
    }

    func testWrappedColumnsAndLanesRenderInDarkAndLight() throws {
        let fixture = wrapFixture()
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture), appearance: appearance.value)
            try check(image, named: "popup-wrap-\(appearance.name)")
        }
    }

    /// The reset control in each state it can show: enabled, greyed at 0,
    /// greyed on a stale row, running, and after a success and a failure.
    func testResetStatesRenderInDarkAndLight() throws {
        var fixture = Fixture()
        fixture.add("ready@example.com", provider: .openai, plan: "pro",
                    windows: weekly(100, resetsIn: 2 * 86_400), resetCredits: 2)
        fixture.add("empty@example.com", provider: .openai, plan: "pro",
                    windows: weekly(40, resetsIn: 2 * 86_400), resetCredits: 0)
        fixture.add("stale-with-resets@example.com", provider: .openai, plan: "pro",
                    windows: weekly(90, resetsIn: 2 * 86_400), isStale: true,
                    fetchedAt: now.addingTimeInterval(-15 * 60), resetCredits: 1)
        fixture.add("running@example.com", provider: .openai, plan: "pro",
                    windows: weekly(95, resetsIn: 86_400), resetCredits: 1)
        let running: Set<UUID> = [fixture.accounts.last!.id]
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture, resetsInFlight: running), appearance: appearance.value)
            try check(image, named: "popup-resets-\(appearance.name)")
        }
    }

    /// A success note and each failure message a live account can meet.
    func testResetNoticesRenderInDarkAndLight() throws {
        var fixture = Fixture()
        fixture.add("done@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 0, session: 0, weekly: 0, resetsIn: 7 * 86_400), resetCredits: 1)
        fixture.add("failed@example.com", provider: .openai, plan: "pro",
                    windows: weekly(88, resetsIn: 86_400), resetCredits: 1)
        fixture.add("nothing@example.com", provider: .openai, plan: "pro",
                    windows: weekly(20, resetsIn: 86_400), resetCredits: 1)
        fixture.add("offline@example.com", provider: .openai, plan: "pro",
                    windows: weekly(60, resetsIn: 86_400), resetCredits: 2)
        let results: [ResetResult] = [.outcome(.reset), .providerError(status: 503), .outcome(.nothingToReset), .unreachable]
        var notices: [UUID: ResetNotice] = [:]
        for (account, result) in zip(fixture.accounts, results) {
            notices[account.id] = ResetMessages.notice(for: result, providerName: account.provider.displayName, now: now)
        }
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture, resetNotices: notices), appearance: appearance.value)
            try check(image, named: "popup-reset-notices-\(appearance.name)")
        }
    }

    func testResetConfirmationRendersInDarkAndLight() throws {
        let view = ResetConfirmation(
            displayName: "work@example.com",
            count: 2,
            windows: [
                UIFixtures.window("5h", label: "5h", used: 70, seconds: 18_000),
                UIFixtures.window("7d", label: "Weekly", used: 10),
            ],
            onConfirm: {},
            onCancel: {}
        )
        .background(Colors.windowBackground)
        for appearance in Self.appearances {
            let image = try render(view, appearance: appearance.value)
            try check(image, named: "reset-confirm-\(appearance.name)")
        }
    }

    // MARK: Panel modals

    /// The reset question as the detail window draws it: a card over the
    /// dimmed accounts, inside the same window. No sheet is attached and no
    /// window is opened, so clicking it never closes the menu bar panel.
    func testInPanelResetConfirmationRendersInDarkAndLight() throws {
        let fixture = referenceFixture()
        let account = try XCTUnwrap(fixture.accounts.first { $0.provider == .openai })
        let cached = fixture.statuses[account.id]
        let view = panel(for: fixture).panelModal(isPresented: true) {
            ResetConfirmation(
                displayName: account.displayName,
                count: cached?.status.resetCreditsAvailable ?? 0,
                windows: Formatting.popupOrder(Formatting.windows(of: cached)),
                onConfirm: {},
                onCancel: {}
            )
        }
        for appearance in Self.appearances {
            var sheets = -1
            let image = try render(view, appearance: appearance.value) { hosting in
                sheets = hosting.window.map { $0.sheets.count + ($0.attachedSheet == nil ? 0 : 1) } ?? -1
            }
            XCTAssertEqual(sheets, 0, "the confirmation is drawn in the panel, not in a sheet")
            try check(image, named: "panel-reset-confirm-\(appearance.name)")
        }
    }

    /// The backdrop covers the whole window, top to bottom, and leaves the
    /// size alone when the content is taller than the card.
    func testPanelModalBackdropCoversTheWholeWindow() throws {
        let fixture = referenceFixture()
        let card = Text("Card").padding(20).frame(width: 200)
        let light = NSAppearance(named: .aqua)!
        let plain = try render(panel(for: fixture).panelModal(isPresented: false) { card }, appearance: light)
        let dimmed = try render(panel(for: fixture).panelModal(isPresented: true) { card }, appearance: light)
        XCTAssertEqual(dimmed.pixelsWide, plain.pixelsWide)
        XCTAssertEqual(dimmed.pixelsHigh, plain.pixelsHigh, "a card shorter than the content adds no height")
        func brightness(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
            try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).brightnessComponent
        }
        for (x, y) in [(2, 2), (2, plain.pixelsHigh - 3), (plain.pixelsWide - 3, plain.pixelsHigh - 3)] {
            XCTAssertLessThan(try brightness(dimmed, x: x, y: y), try brightness(plain, x: x, y: y) - 0.1,
                              "dimmed at (\(x), \(y))")
        }
    }

    /// A card taller than the content grows the window to fit it, with the
    /// card's margin above and below. Without a card the size is the content's.
    func testPanelModalGrowsAShortWindowToFitTheCard() {
        let card = Color.gray.frame(width: 300, height: 260)
        let content = Color.clear.frame(width: PopupMetrics.width, height: 40)
        XCTAssertEqual(fittedHeight(content.panelModal(isPresented: false) { card }), 40)
        XCTAssertEqual(fittedHeight(content.panelModal(isPresented: true) { card }),
                       260 + 2 * PanelModal<EmptyView>.margin, accuracy: 0.5)
    }

    /// A login in progress is drawn inside the real detail window, which
    /// grows past its empty state to fit it. The flow lives on the model:
    /// the window closing (the user went to the browser) leaves it running,
    /// with the pasted code, and the next window shows it again.
    func testLoginCardRendersInsideTheDetailWindowAndOutlivesIt() async throws {
        let harness = ModelHarness(fixture: PollingFixture())
        addTeardownBlock { @MainActor in await harness.cleanUp() }
        let emptyHeight = try render(DetailWindow(model: harness.model), appearance: Self.appearances[0].value).pixelsHigh

        let flow = LoginFlow(provider: .openai, mode: .manualCode, replacing: nil)
        flow.phase = .awaitingCode
        flow.pastedCode = "pasted-code"
        harness.model.activeLogin = flow
        for appearance in Self.appearances {
            var sheets = -1
            let image = try render(DetailWindow(model: harness.model), appearance: appearance.value) { hosting in
                sheets = hosting.window.map { $0.sheets.count + ($0.attachedSheet == nil ? 0 : 1) } ?? -1
            }
            XCTAssertEqual(sheets, 0, "the login is drawn in the panel, not in a sheet")
            XCTAssertGreaterThan(image.pixelsHigh, emptyHeight, "the window grew to fit the login card")
            try check(image, named: "panel-login-\(appearance.name)")
        }

        // Every window above is gone; the login is not.
        XCTAssertTrue(harness.model.activeLogin === flow)
        XCTAssertEqual(flow.pastedCode, "pasted-code")
        XCTAssertEqual(flow.phase, .awaitingCode)
        harness.model.activeLogin = nil
    }

    /// The bars sliding up after a reset, as five frames at fixed progress
    /// 0, 0.25, 0.5, 0.75 and 1 of the fill animation. Each frame is the real
    /// `WindowBar` drawn at the reading SwiftUI interpolates to at that point
    /// of the ease-in-out curve (see `ResetAnimationFrames`), so the
    /// percentage text and the band color are shown per frame too. Left:
    /// from 12% left (the warning band) to 100%. Right: from 0% (red) to 100%.
    func testResetSuccessBarsFramesRenderInDarkAndLight() throws {
        let now = now
        func bar(_ fraction: Double) -> some View {
            WindowBar(
                window: UsageWindow(key: "7d", label: "Weekly", usedPercent: (1 - fraction) * 100,
                                    resetsAt: now.addingTimeInterval(7 * 86_400), durationSeconds: 604_800),
                providerName: "Codex",
                displayName: "frames@example.com",
                dimmed: false,
                now: now
            )
        }
        let frames = VStack(alignment: .leading, spacing: 14) {
            ForEach(ResetAnimationFrames.progress, id: \.self) { progress in
                HStack(alignment: .top, spacing: 16) {
                    Text("t = \(String(format: "%.2f", progress))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    bar(ResetAnimationFrames.fraction(at: progress))
                    bar(ResetAnimationFrames.fraction(at: progress, from: 0))
                }
            }
        }
        .padding(20)
        .background(Colors.windowBackground)
        for appearance in Self.appearances {
            let image = try render(frames, appearance: appearance.value)
            try check(image, named: "reset-success-bars-\(appearance.name)")
        }
    }

    /// The band color the fill is drawn in at the first and last frame:
    /// 12% left reads yellow, 0% reads red, and 100% reads green.
    func testResetSuccessBarsChangeBandColor() throws {
        let appearance = NSAppearance(named: .darkAqua)!
        func fillColor(_ fraction: Double) throws -> NSColor {
            let remaining = Formatting.remainingPercent(used: (1 - fraction) * 100)
            let bar = UsageBar(fraction: fraction, band: Colors.band(forRemaining: remaining), dimmed: false,
                               width: PopupMetrics.columnWidth)
                .padding(4)
                .background(Colors.windowBackground)
            let rep = try render(bar, appearance: appearance)
            let scale = CGFloat(rep.pixelsWide) / (PopupMetrics.columnWidth + 8)
            let color = rep.colorAt(x: Int(6 * scale), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            return try XCTUnwrap(color)
        }
        let start = try fillColor(ResetAnimationFrames.fraction(at: 0))
        let redStart = try fillColor(ResetAnimationFrames.fraction(at: 0, from: 0))
        let end = try fillColor(ResetAnimationFrames.fraction(at: 1))
        XCTAssertEqual(Colors.band(forRemaining: 12), .warning)
        XCTAssertGreaterThan(start.redComponent, 0.8, "12% left draws the yellow fill")
        XCTAssertGreaterThan(start.greenComponent, 0.6)
        XCTAssertLessThan(start.blueComponent, 0.35)
        XCTAssertGreaterThan(redStart.redComponent, 2 * redStart.greenComponent, "an empty window's track reads red")
        XCTAssertGreaterThan(redStart.redComponent, 2 * redStart.blueComponent)
        XCTAssertLessThan(end.redComponent, 0.3, "100% left draws the green fill")
        XCTAssertGreaterThan(end.greenComponent, 0.55)
    }

    // MARK: After a reset (ISC-225, 226, 229, 230, 241)

    private func singleRow(_ account: Account, cached: CachedStatus?, notice: ResetNotice?, now: Date) -> some View {
        AccountsPanel(
            accounts: [account],
            statuses: cached.map { [account.id: $0] } ?? [:],
            planLabels: [account.id: "pro"],
            now: now,
            resetNotices: notice.map { [account.id: $0] } ?? [:]
        )
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
    }

    /// A reset that only partly clears the window: the provider's fresh
    /// reading says 40% used, so the bar settles at 60% left, not 100%.
    func testResetSuccessPartialRenders() async throws {
        let f = PollingFixture()
        let account = try await f.addAccount(.openai, email: "partial@example.com")
        f.openai.setResetCredits(2)
        f.openai.script([.succeed(usedPercent: 88)], for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.stop()
        f.openai.setResetCredits(1)
        f.openai.script([.succeed(usedPercent: 40)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        let entry = try await f.requireEntry(account)
        let now = f.clock.now()
        await f.cleanUp()

        XCTAssertEqual(result, .outcome(.reset))
        let window = try XCTUnwrap(entry.status.windows.first)
        XCTAssertEqual(Formatting.remainingPercent(used: window.usedPercent), 60, "the reported level, not 100%")
        XCTAssertEqual(entry.status.resetCreditsAvailable, 1)
        let notice = ResetMessages.notice(for: result, providerName: "Codex", now: now)
        for appearance in Self.appearances {
            let image = try render(singleRow(account, cached: entry, notice: notice, now: now), appearance: appearance.value)
            try check(image, named: "reset-success-partial-\(appearance.name)")
        }
    }

    /// A reset that clears only the 5-hour window: the weekly column is
    /// pixel-identical before and after.
    func testResetSuccessFiveHourOnlyRenders() throws {
        let account = UIFixtures.account("five-hour@example.com", provider: .anthropic)
        let weekly = UIFixtures.window("7d", label: "Weekly", used: 60, resetsIn: 3 * 86_400, seconds: 604_800)
        let beforeWindows = [UIFixtures.window("5h", label: "5h", used: 95, resetsIn: 2 * 3600, seconds: 18_000), weekly]
        let afterWindows = [UIFixtures.window("5h", label: "5h", used: 0, resetsIn: 5 * 3600, seconds: 18_000), weekly]
        let before = UIFixtures.cached(for: account, windows: beforeWindows, planLabel: "max", resetCreditsAvailable: 2)
        let after = UIFixtures.cached(for: account, windows: afterWindows, planLabel: "max", resetCreditsAvailable: 1)
        let notice = ResetMessages.notice(for: .outcome(.reset), providerName: "Claude", now: now)

        for appearance in Self.appearances {
            let beforeImage = try render(singleRow(account, cached: before, notice: nil, now: now), appearance: appearance.value)
            let afterImage = try render(singleRow(account, cached: after, notice: notice, now: now), appearance: appearance.value)
            try check(beforeImage, named: "reset-before-5h-only-\(appearance.name)")
            try check(afterImage, named: "reset-success-5h-only-\(appearance.name)")

            // The weekly window is the second column.
            let scale = CGFloat(afterImage.pixelsWide) / PopupMetrics.width
            let left = PopupMetrics.columnsLeading + PopupMetrics.columnWidth + PopupMetrics.columnGap
            let columns = Int((left * scale).rounded(.up))..<Int(((left + PopupMetrics.columnWidth) * scale).rounded(.down))
            let rows = 0..<min(beforeImage.pixelsHigh, afterImage.pixelsHigh)
            XCTAssertTrue(Self.samePixels(beforeImage, afterImage, columns: columns, rows: rows),
                          "the weekly column changed (\(appearance.name))")
            let fiveHour = Int((PopupMetrics.columnsLeading * scale).rounded(.up))..<Int(((PopupMetrics.columnsLeading + PopupMetrics.columnWidth) * scale).rounded(.down))
            XCTAssertFalse(Self.samePixels(beforeImage, afterImage, columns: fiveHour, rows: rows), "the 5-hour column did change")
        }
    }

    /// The read right after the reset failed: the row still says the reset
    /// was used, and the bars keep the last reading, dimmed, with its age.
    func testResetSuccessReadFailedRenders() async throws {
        let f = PollingFixture()
        let account = try await f.addAccount(.openai, email: "read-failed@example.com")
        f.openai.setResetCredits(2)
        // A usage read that times out, as URLSession reports it: what a read
        // after a reset really meets, drawn as the row's normal failed-read
        // state.
        let timedOut = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        f.openai.script([.succeed(usedPercent: 88), .fail(.transport(timedOut))], for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.stop()
        let polledAt = f.clock.now()
        await f.clock.advance(by: 7 * 60)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        let entry = try await f.requireEntry(account)
        let now = f.clock.now()
        await f.cleanUp()

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.status.fetchedAt, polledAt, "the bars keep the last reading's time")
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 88)
        XCTAssertEqual(Formatting.agePhrase(since: entry.status.fetchedAt, now: now), "updated 7m ago")
        guard case .error(let shown) = entry.status.state else {
            return XCTFail("expected the failed-read state, got \(entry.status.state)")
        }
        XCTAssertFalse(shown.contains("httpStatus"), "the row shows the app's own words, not an enum case")
        let notice = try XCTUnwrap(ResetMessages.notice(for: result, providerName: "Codex", now: now))
        XCTAssertEqual(notice.text, ResetMessages.success)
        for appearance in Self.appearances {
            let image = try render(singleRow(account, cached: entry, notice: notice, now: now), appearance: appearance.value)
            try check(image, named: "reset-success-read-failed-\(appearance.name)")
        }
    }

    /// The footer's "Last updated" time moves to the fresh reading's time:
    /// the whole detail window, before and after a reset, from a real model.
    func testResetSuccessFooterRenders() async throws {
        let harness = ModelHarness(fixture: PollingFixture())
        let f = harness.fixture
        let account = try await f.addAccount(.openai, email: "footer@example.com")
        f.openai.setResetCredits(2)
        f.openai.script([.succeed(usedPercent: 88)], for: account)
        await harness.start()
        await harness.stopPolling()
        let model = harness.model
        let polledAt = try XCTUnwrap(model.lastUpdated)

        for appearance in Self.appearances {
            try check(try render(DetailWindow(model: model), appearance: appearance.value), named: "reset-before-footer-\(appearance.name)")
        }

        await f.clock.advance(by: 125)
        let readAt = f.clock.now()
        f.openai.setResetCredits(1)
        f.openai.script([.succeed(usedPercent: 0)], for: account)
        model.useReset(account)
        let running = try XCTUnwrap(model.resetTasks[account.id])
        await running.value
        await harness.waitForStatus("fresh reading published") { $0[account.id]?.status.fetchedAt == readAt }

        XCTAssertEqual(model.lastUpdated, readAt, "the footer follows the fresh reading")
        XCTAssertNotEqual(Formatting.clockTimeWithSeconds(polledAt), Formatting.clockTimeWithSeconds(readAt))
        for appearance in Self.appearances {
            try check(try render(DetailWindow(model: model), appearance: appearance.value), named: "reset-success-\(appearance.name)")
        }
        await harness.cleanUp()
    }

    /// The HTTP 503 message in both row shapes, in full on one line: a Codex
    /// row (one window, count in the second slot) and a Claude row (three
    /// windows, count alone on a second line).
    func testResetHTTPErrorRendersInBothRowShapes() throws {
        var fixture = Fixture()
        fixture.add("codex-503@example.com", provider: .openai, plan: "pro",
                    windows: weekly(88, resetsIn: 86_400), resetCredits: 1)
        fixture.add("claude-503@example.com", provider: .anthropic, plan: "max",
                    windows: claudeWindows(fable: 40, session: 95, weekly: 60, resetsIn: 3 * 86_400), resetCredits: 1)
        var notices: [UUID: ResetNotice] = [:]
        for account in fixture.accounts {
            notices[account.id] = ResetMessages.notice(for: .providerError(status: 503), providerName: account.provider.displayName, now: now)
        }
        for appearance in Self.appearances {
            let image = try render(panel(for: fixture, resetNotices: notices), appearance: appearance.value)
            try check(image, named: "reset-http-error-\(appearance.name)")
        }
    }

    // MARK: Each result on a real row (ISC-234 through ISC-246)

    /// A model over the mocks whose clock starts at the wall clock, so a time
    /// in a message is still ahead when the model builds it with `Date()`.
    /// The success note stays until the harness opens its fade gate.
    private func liveHarness(scheduler: ((PollingFixture) -> PollScheduler)? = nil) -> ModelHarness {
        let fixture = PollingFixture(clock: TestClock(start: Date()))
        return ModelHarness(fixture: fixture, scheduler: scheduler?(fixture))
    }

    private static func liveWindows(_ start: Date, claudeShaped: Bool, used: Double) -> [UsageWindow] {
        let day: TimeInterval = 86_400
        let weekly = UsageWindow(key: "7d", label: "Weekly", usedPercent: used,
                                 resetsAt: start.addingTimeInterval(2 * day + 3 * 3600), durationSeconds: 604_800)
        guard claudeShaped else { return [weekly] }
        return [
            UsageWindow(key: "5h", label: "5h", usedPercent: min(100, used + 20),
                        resetsAt: start.addingTimeInterval(2 * 3600), durationSeconds: 18_000),
            weekly,
            UsageWindow(key: UsageWindow.scopedPrefix + "Fable", label: "Fable", usedPercent: used / 2,
                        resetsAt: start.addingTimeInterval(2 * day + 3 * 3600), durationSeconds: 604_800),
        ]
    }

    /// Waits until the model shows exactly what the cache holds for `account`.
    private func caughtUp(_ harness: ModelHarness, _ account: Account) async {
        let entry = await harness.fixture.cache.entry(for: account.id)
        await harness.waitForStatus("model caught up with the cache") { $0[account.id] == entry }
    }

    /// Clicks Use reset (already confirmed) and waits for the run to finish.
    private func useReset(_ account: Account, in harness: ModelHarness) async throws {
        harness.model.useReset(account)
        try await XCTUnwrap(harness.model.resetTasks[account.id], "no reset started").value
        await caughtUp(harness, account)
    }

    private func modelRow(_ account: Account, in harness: ModelHarness) -> some View {
        singleRow(account, cached: harness.model.statuses[account.id],
                  notice: harness.model.resetNotices[account.id], now: harness.fixture.clock.now())
    }

    private func modelPanel(_ harness: ModelHarness) -> some View {
        AccountsPanel(
            accounts: harness.model.accounts,
            statuses: harness.model.statuses,
            planLabels: Dictionary(uniqueKeysWithValues: harness.model.accounts.map { ($0.id, "pro") }),
            now: harness.fixture.clock.now(),
            resetsInFlight: harness.model.resetsInFlight,
            resetNotices: harness.model.resetNotices
        )
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
    }

    /// One Codex row holding `credits` resets, polled once through a real
    /// model, then one confirmed reset the mock answers with `answer`.
    private func oneReset(
        _ email: String,
        credits: Int = 2,
        creditsAfter: Int? = nil,
        answer: MockUsageProvider.ResetBehavior
    ) async throws -> (ModelHarness, Account) {
        let harness = liveHarness()
        let f = harness.fixture
        let account = try await f.addAccount(.openai, email: email)
        f.openai.setResetCredits(credits)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(f.clock.now(), claudeShaped: false, used: 88)), for: account)
        await harness.start()
        await harness.stopPolling()
        if let creditsAfter { f.openai.setResetCredits(creditsAfter) }
        f.openai.scriptResets([answer], for: account)
        try await useReset(account, in: harness)
        return (harness, account)
    }

    private func renderRow(_ account: Account, in harness: ModelHarness, named name: String) throws {
        for appearance in Self.appearances {
            try check(try render(modelRow(account, in: harness), appearance: appearance.value), named: "\(name)-\(appearance.name)")
        }
    }

    /// ISC-234: no credit. The provider's fresh count is 0 and the button greys.
    func testResetNoCreditRenders() async throws {
        let (h, account) = try await oneReset("no-credit@example.com", credits: 1, creditsAfter: 0, answer: .answer(.noCredit))
        let cached = try XCTUnwrap(h.model.statuses[account.id])
        XCTAssertEqual(h.model.resetNotices[account.id]?.text, "No resets available")
        XCTAssertEqual(cached.status.resetCreditsAvailable, 0, "the provider's fresh 0")
        XCTAssertEqual(h.fixture.openai.fetchCount(for: account), 2, "read once after the answer")
        XCTAssertEqual(ResetCreditsColumn.disabledReason(count: 0, dimmed: AccountRow.isDimmed(cached)), "No resets available")
        try renderRow(account, in: h, named: "reset-no-credit")
        await h.cleanUp()
    }

    /// ISC-236: cooldown, with the time in the app's clock format and the
    /// count unchanged.
    func testResetCooldownRenders() async throws {
        let until = Date().addingTimeInterval(2 * 3600)
        let (h, account) = try await oneReset("cooldown@example.com", answer: .answer(.cooldown(until: until)))
        XCTAssertEqual(h.model.resetNotices[account.id]?.text, "Reset on cooldown until \(Formatting.clockTime(until))")
        XCTAssertEqual(h.model.statuses[account.id]?.status.resetCreditsAvailable, 2, "count unchanged")
        XCTAssertEqual(h.fixture.openai.fetchCount(for: account), 1, "no read after a cooldown")
        try renderRow(account, in: h, named: "reset-cooldown")
        await h.cleanUp()
    }

    /// ISC-237: not available, in the generic words with no reason code.
    func testResetNotAvailableRenders() async throws {
        let (h, account) = try await oneReset("not-available@example.com", answer: .answer(.notAvailable))
        let text = try XCTUnwrap(h.model.resetNotices[account.id]?.text)
        XCTAssertEqual(text, "Resets aren't available for this account right now")
        XCTAssertFalse(text.contains("_"), "no provider code")
        try renderRow(account, in: h, named: "reset-not-available")
        await h.cleanUp()
    }

    /// ISC-238: rate limited on the reset, with the time to try again.
    func testResetRateLimitedRenders() async throws {
        let (h, account) = try await oneReset("rate-limited@example.com", answer: .fail(.rateLimited(retryAfter: 1_800)))
        let until = h.fixture.clock.now().addingTimeInterval(1_800)
        XCTAssertEqual(h.model.resetNotices[account.id]?.text, "Codex is limiting requests — try again at \(Formatting.clockTime(until))")
        XCTAssertEqual(h.model.statuses[account.id]?.status.state, .ok, "the row's own reading is untouched")
        try renderRow(account, in: h, named: "reset-rate-limited")
        await h.cleanUp()
    }

    /// ISC-239: sign-in needed. The row switches to its own sign-in state,
    /// keeps its last numbers dimmed, and shows no reset message.
    func testResetNeedsLoginRenders() async throws {
        let (h, account) = try await oneReset("needs-login@example.com", answer: .fail(.needsLogin))
        let cached = try XCTUnwrap(h.model.statuses[account.id])
        XCTAssertNil(h.model.resetNotices[account.id], "no reset message: the row's state says it")
        XCTAssertEqual(cached.status.state, .needsLogin)
        XCTAssertEqual(cached.lastGoodWindows?.first?.usedPercent, 88, "last good numbers kept")
        XCTAssertTrue(AccountRow.isDimmed(cached))
        XCTAssertEqual(h.model.accounts.map(\.id), [account.id], "the row is kept")
        try renderRow(account, in: h, named: "reset-needs-login")
        await h.cleanUp()
    }

    /// ISC-242: an answer this build does not know is never success.
    func testResetUnexpectedRenders() async throws {
        let (h, account) = try await oneReset("unexpected@example.com", answer: .answer(.unexpected))
        let notice = try XCTUnwrap(h.model.resetNotices[account.id])
        XCTAssertEqual(notice.text, "Unexpected answer from Codex")
        XCTAssertEqual(notice.kind, .failure)
        try renderRow(account, in: h, named: "reset-unexpected")
        await h.cleanUp()
    }

    /// ISC-243: a 500 whose body echoes a bearer token and a key, through the
    /// real Codex adapter. Nothing from the body reaches the row.
    func testResetHostileHTTPErrorRendersNoToken() async throws {
        let hostile = #"{"error":{"message":"upstream failed for Authorization: Bearer eyJabc.def.ghi key sk-live-abcdef0123456789"}}"#
        let usage = String(decoding: try TestFixtures.data("wham-usage"), as: UTF8.self)
        let client = OpenAIMockHTTPClient(responses: [.json(usage), .json(500, hostile), .json(usage)])
        let harness = liveHarness { fixture in
            PollScheduler(
                store: fixture.store,
                providers: [.openai: OpenAIProvider(client: client)],
                resolver: PassthroughCredentialResolver(),
                cache: fixture.cache,
                settings: fixture.settings,
                clock: fixture.clock,
                postResetReadDelay: fixture.postResetReadDelay
            )
        }
        let account = try await harness.fixture.addAccount(.openai, email: "hostile@example.com")
        await harness.start()
        await harness.stopPolling()
        try await useReset(account, in: harness)

        XCTAssertEqual(client.requests.count, 3, "read, reset, and the read after the 5xx")
        let text = try XCTUnwrap(harness.model.resetNotices[account.id]?.text)
        XCTAssertEqual(text, "Codex had a problem (HTTP 500). Try again — a retry never spends a second reset.")
        for secret in ["eyJ", "Bearer", "sk-", "abc.def.ghi", "upstream"] {
            XCTAssertFalse(text.contains(secret), "the message shows \(secret)")
        }
        XCTAssertEqual(harness.model.statuses[account.id]?.status.state, .ok)
        try renderRow(account, in: harness, named: "reset-http-error-hostile")
        await harness.cleanUp()
    }

    /// ISC-245: a failure on one row leaves the other row exactly as it was:
    /// its reading, its count, no message, and the same pixels as its idle PNG.
    func testResetTwoRowsOneFailedRenders() async throws {
        let harness = liveHarness()
        let f = harness.fixture
        let failing = try await f.addAccount(.openai, email: "failing@example.com")
        let idle = try await f.addAccount(.openai, email: "idle@example.com")
        f.openai.setResetCredits(2)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(f.clock.now(), claudeShaped: false, used: 88)), for: failing)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(f.clock.now(), claudeShaped: false, used: 30)), for: idle)
        await harness.start()
        await harness.stopPolling()
        let idleBefore = try XCTUnwrap(harness.model.statuses[idle.id])
        var idleImages: [String: NSBitmapImageRep] = [:]
        for appearance in Self.appearances {
            let image = try render(modelRow(idle, in: harness), appearance: appearance.value)
            idleImages[appearance.name] = image
            try check(image, named: "reset-two-rows-idle-\(appearance.name)")
        }
        f.openai.scriptResets([.fail(.httpStatus(503))], for: failing)
        try await useReset(failing, in: harness)

        XCTAssertEqual(harness.model.resetNotices[failing.id]?.text,
                       "Codex had a problem (HTTP 503). Try again — a retry never spends a second reset.")
        XCTAssertNil(harness.model.resetNotices[idle.id], "no message on the other row")
        XCTAssertEqual(harness.model.statuses[idle.id], idleBefore, "the other row's bars and count are unchanged")
        XCTAssertEqual(f.openai.fetchCount(for: idle), 1, "the other row was not read")
        XCTAssertEqual(f.openai.resetCalls.map(\.accountID), [failing.id])
        for appearance in Self.appearances {
            let after = try render(modelRow(idle, in: harness), appearance: appearance.value)
            let before = try XCTUnwrap(idleImages[appearance.name])
            XCTAssertEqual(after.pixelsHigh, before.pixelsHigh)
            XCTAssertTrue(Self.samePixels(before, after, columns: 0..<min(before.pixelsWide, after.pixelsWide)),
                          "the other row matches its idle PNG (\(appearance.name))")
            try check(try render(modelPanel(harness), appearance: appearance.value), named: "reset-two-rows-one-failed-\(appearance.name)")
        }
        await harness.cleanUp()
    }

    /// ISC-246: two Codex rows and one Claude-shaped row, all holding resets;
    /// a reset on one Codex row changes only that row.
    func testResetThreeRowsOneSuccessRenders() async throws {
        let harness = liveHarness()
        let f = harness.fixture
        let start = f.clock.now()
        let target = try await f.addAccount(.openai, email: "codex-target@example.com")
        let codex = try await f.addAccount(.openai, email: "codex-other@example.com")
        let claude = try await f.addAccount(.anthropic, email: "claude-other@example.com")
        f.openai.setResetCredits(2)
        f.anthropic.setResetCredits(1)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(start, claudeShaped: false, used: 95)), for: target)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(start, claudeShaped: false, used: 40)), for: codex)
        f.anthropic.setBehavior(.succeedWindows(Self.liveWindows(start, claudeShaped: true, used: 60)), for: claude)
        await harness.start()
        await harness.stopPolling()
        let others = [codex, claude]
        var before: [UUID: CachedStatus] = [:]
        var images: [String: NSBitmapImageRep] = [:]
        for account in others {
            before[account.id] = try XCTUnwrap(harness.model.statuses[account.id])
            for appearance in Self.appearances {
                images["\(account.id)-\(appearance.name)"] = try render(modelRow(account, in: harness), appearance: appearance.value)
            }
        }
        XCTAssertEqual(before[claude.id]?.status.windows.count, 3, "a Claude-shaped row")
        for appearance in Self.appearances {
            try check(try render(modelPanel(harness), appearance: appearance.value), named: "reset-three-rows-before-\(appearance.name)")
        }
        f.openai.setResetCredits(1)
        f.openai.setBehavior(.succeedWindows(Self.liveWindows(start, claudeShaped: false, used: 0)), for: target)
        f.openai.scriptResets([.answer(.reset)], for: target)
        try await useReset(target, in: harness)

        XCTAssertEqual(harness.model.resetNotices[target.id]?.text, ResetMessages.success)
        XCTAssertEqual(harness.model.statuses[target.id]?.status.windows.first?.usedPercent, 0)
        XCTAssertEqual(harness.model.statuses[target.id]?.status.resetCreditsAvailable, 1)
        for account in others {
            XCTAssertEqual(harness.model.statuses[account.id], before[account.id], "\(account.email) is unchanged")
            XCTAssertNil(harness.model.resetNotices[account.id])
            XCTAssertEqual(f.mock(for: account.provider).fetchCount(for: account), 1, "\(account.email) was not read")
            for appearance in Self.appearances {
                let after = try render(modelRow(account, in: harness), appearance: appearance.value)
                let image = try XCTUnwrap(images["\(account.id)-\(appearance.name)"])
                XCTAssertTrue(Self.samePixels(image, after, columns: 0..<min(image.pixelsWide, after.pixelsWide)),
                              "\(account.email) draws the same (\(appearance.name))")
            }
        }
        XCTAssertEqual(f.openai.resetCalls.map(\.accountID), [target.id])
        XCTAssertEqual(f.anthropic.resetCount, 0)
        for appearance in Self.appearances {
            try check(try render(modelPanel(harness), appearance: appearance.value), named: "reset-three-rows-one-success-\(appearance.name)")
        }
        await harness.cleanUp()
    }

    func testMenuBarLabelsRenderInDarkAndLight() throws {
        let fixture = referenceFixture()
        let ordered = AccountOrder.grouped(fixture.accounts)
        var labels = ordered.enumerated().map { offset, account in
            Formatting.barLabel(account: account, index: offset + 1, cached: fixture.statuses[account.id], now: now)
        }
        XCTAssertEqual(labels.first?.plainText, "1: 5h 100% / WK 100% / FB 100%")
        // Stale labels, one of them at 0%: dimmed, but the 0% stays red.
        let states = statesFixture()
        let staleLabels = AccountOrder.grouped(states.accounts).enumerated().compactMap { offset, account -> BarLabel? in
            guard states.statuses[account.id]?.isStale == true else { return nil }
            return Formatting.barLabel(account: account, index: offset + 1, cached: states.statuses[account.id], now: now)
        }
        XCTAssertTrue(staleLabels.contains { $0.dimmed && $0.segments.contains { $0.band == .critical } })
        labels += staleLabels
        // The menu bar draws the label as one image; render exactly that.
        let images = labels.map(MenuBarImage.image(for:))
        for appearance in Self.appearances {
            let strip = try MenuBarRendering.render(images, appearance: appearance.value)
            try check(strip, named: "menubar-\(appearance.name)")
        }
    }

    // MARK: Layout: the reset control costs no height

    /// The "Manual resets" column exactly as v0.2.0 drew it, before the Use
    /// reset control existed: the title and the count, nothing else.
    private struct CountOnlyColumn: View {
        let count: Int
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual resets")
                    .font(.system(size: 13))
                    .lineLimit(1)
                (Text("\(count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                 + Text("  available")
                    .font(.system(size: 13)))
                    .lineLimit(1)
            }
            .frame(width: PopupMetrics.columnWidth, alignment: .leading)
        }
    }

    private func fittedHeight<V: View>(_ view: V, width: CGFloat? = nil) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func row(_ email: String, provider: Provider, windows: [UsageWindow], resetCredits: Int?,
                     isResetting: Bool = false, notice: ResetNotice? = nil) -> some View {
        let account = UIFixtures.account(email, provider: provider)
        return AccountRow(
            account: account,
            number: 1,
            cached: UIFixtures.cached(for: account, windows: windows, planLabel: "pro", resetCreditsAvailable: resetCredits),
            planLabel: "pro",
            now: now,
            isFirstInSection: true,
            isLastInSection: true,
            isResetting: isResetting,
            resetNotice: notice
        )
        .background(Colors.windowBackground)
    }

    /// At rest the Use reset button sits on the count line, so the column is
    /// exactly as tall as v0.2.0's count-only column, and a row with a count
    /// is exactly as tall as it was before the control existed.
    func testResetControlAddsNoHeightAtRest() {
        let countOnly = fittedHeight(CountOnlyColumn(count: 2))
        XCTAssertGreaterThan(countOnly, 30)
        for (count, dimmed) in [(2, false), (0, false), (1, true), (12, false)] {
            XCTAssertEqual(fittedHeight(ResetCreditsColumn(count: count, dimmed: dimmed)), countOnly,
                           "count \(count), dimmed \(dimmed)")
        }

        let width = PopupMetrics.width
        let oneWindow = weekly(40, resetsIn: 86_400)
        let withoutCount = fittedHeight(row("a@example.com", provider: .openai, windows: oneWindow, resetCredits: nil), width: width)
        let withCount = fittedHeight(row("a@example.com", provider: .openai, windows: oneWindow, resetCredits: 2), width: width)
        XCTAssertEqual(withCount, withoutCount, "one window plus a count: the window column sets the height, as in v0.2.0")

        // Three windows push the count onto a second line of columns; that
        // line is exactly v0.2.0's count-only column.
        let three = claudeWindows(fable: 10, session: 20, weekly: 30, resetsIn: 86_400)
        let threeWithout = fittedHeight(row("b@example.com", provider: .anthropic, windows: three, resetCredits: nil), width: width)
        let threeWith = fittedHeight(row("b@example.com", provider: .anthropic, windows: three, resetCredits: 1), width: width)
        XCTAssertEqual(threeWith, threeWithout + PopupMetrics.columnLineSpacing + countOnly)

        // The spinner and a short message take the third line, adding at
        // most one line past the window column's own three. A message too
        // long for that line moves under the columns, where it is capped at
        // two lines however long it is.
        let running = fittedHeight(row("a@example.com", provider: .openai, windows: oneWindow, resetCredits: 2, isResetting: true), width: width)
        XCTAssertLessThanOrEqual(running, withoutCount + 16)
        let long = ResetNotice(String(repeating: "Codex couldn't use the reset (HTTP 404). Nothing was changed. ", count: 12), kind: .failure)
        let short = ResetNotice("Reset used — limits refreshed", kind: .success)
        let withLong = fittedHeight(row("a@example.com", provider: .openai, windows: oneWindow, resetCredits: 2, notice: long), width: width)
        let withShort = fittedHeight(row("a@example.com", provider: .openai, windows: oneWindow, resetCredits: 2, notice: short), width: width)
        XCTAssertLessThanOrEqual(withShort, withoutCount + 16, "a one-line message fits in about the window column's height plus one line")
        let growth = withLong - withShort
        XCTAssertGreaterThan(growth, 20, "a long message takes lines of its own")
        XCTAssertLessThanOrEqual(growth, 6 + 2 * 16, "two of them at most")
    }

    /// Five Claude rows with three windows and three Codex rows with one
    /// window and a count: the list v0.2.0 showed without scrolling still
    /// shows every row without scrolling.
    func testEightAccountListDoesNotScroll() throws {
        let fixture = referenceFixture()
        XCTAssertEqual(fixture.accounts.filter { $0.provider == .anthropic }.count, 5)
        XCTAssertEqual(fixture.statuses.values.filter { $0.status.resetCreditsAvailable != nil }.count, 3)
        for appearance in Self.appearances {
            var scroll: (content: CGFloat, visible: CGFloat)?
            let image = try render(panel(for: fixture), appearance: appearance.value) { hosting in
                scroll = Self.scrollExtent(in: hosting)
            }
            let extent = try XCTUnwrap(scroll, "the list's scroll view")
            XCTAssertLessThanOrEqual(extent.content, PopupMetrics.maxListHeight)
            XCTAssertLessThanOrEqual(extent.content, extent.visible + 0.5, "the list scrolls")
            try check(image, named: "popup-eight-\(appearance.name)")
        }
    }

    /// Twelve accounts overflow the list, which then scrolls with a visible
    /// scroller. The "…" button stays right of the last column.
    func testScrollingListKeepsActionsClearOfColumns() throws {
        var fixture = referenceFixture()
        let day: TimeInterval = 86_400
        for index in 0..<4 {
            fixture.add("extra-\(index)@example.com", provider: index.isMultiple(of: 2) ? .anthropic : .openai, plan: "pro",
                        windows: index.isMultiple(of: 2)
                            ? claudeWindows(fable: 40, session: 30, weekly: 20, resetsIn: 2 * day)
                            : weekly(70, resetsIn: 2 * day),
                        resetCredits: index.isMultiple(of: 2) ? nil : 3)
        }
        for appearance in Self.appearances {
            var scroll: (content: CGFloat, visible: CGFloat)?
            let image = try render(panel(for: fixture), appearance: appearance.value, legacyScrollers: true) { hosting in
                scroll = Self.scrollExtent(in: hosting)
            }
            let extent = try XCTUnwrap(scroll)
            XCTAssertGreaterThan(extent.content, extent.visible, "twelve accounts scroll")
            try check(image, named: "popup-scrolling-\(appearance.name)")
        }
    }

    /// A row narrowed by a visible scroller draws its columns exactly as a
    /// full-width row does: the "…" button never lands on them.
    func testActionsButtonNeverCoversAColumn() throws {
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let columnsEnd = PopupMetrics.columnsLeading + PopupMetrics.columnsLineWidth
        let appearance = NSAppearance(named: .darkAqua)!
        let windows = claudeWindows(fable: 100, session: 100, weekly: 100, resetsIn: 86_400)
        let full = try render(row("c@example.com", provider: .anthropic, windows: windows, resetCredits: nil)
            .frame(width: PopupMetrics.width), appearance: appearance)
        for trim in [scroller, scroller + 2] {
            let narrow = try render(row("c@example.com", provider: .anthropic, windows: windows, resetCredits: nil)
                .frame(width: PopupMetrics.width - trim), appearance: appearance)
            let scale = CGFloat(narrow.pixelsWide) / (PopupMetrics.width - trim)
            XCTAssertEqual(full.pixelsHigh, narrow.pixelsHigh)
            let columnsPixels = Int((columnsEnd * scale).rounded(.up))
            XCTAssertTrue(Self.samePixels(full, narrow, columns: 0..<columnsPixels),
                          "the actions button overlaps the last column at width \(PopupMetrics.width - trim)")
            // And the button is still drawn, between the last column and the edge.
            XCTAssertGreaterThan(Self.distinctColors(narrow, columns: columnsPixels..<narrow.pixelsWide), 2,
                                 "no actions button at width \(PopupMetrics.width - trim)")
        }
        let scale = CGFloat(full.pixelsWide) / PopupMetrics.width
        XCTAssertGreaterThan(Self.distinctColors(full, columns: Int((columnsEnd * scale).rounded(.up))..<full.pixelsWide), 2)
    }

    private static func samePixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>, rows: Range<Int>? = nil) -> Bool {
        for y in rows ?? 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in columns where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                return false
            }
        }
        return true
    }

    private static func distinctColors(_ rep: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var seen = Set<NSColor>()
        for y in 0..<rep.pixelsHigh {
            for x in columns {
                if let color = rep.colorAt(x: x, y: y) { seen.insert(color) }
            }
        }
        return seen.count
    }

    /// The list's scroll view: its content height and its visible height.
    private static func scrollExtent(in view: NSView) -> (content: CGFloat, visible: CGFloat)? {
        guard let scrollView = scrollView(in: view), let document = scrollView.documentView else { return nil }
        return (document.frame.height, scrollView.contentView.bounds.height)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: Rendering

    private static let appearances: [(name: String, value: NSAppearance)] = [
        ("dark", NSAppearance(named: .darkAqua)!),
        ("light", NSAppearance(named: .aqua)!),
    ]

    private func panel(
        for fixture: Fixture,
        resetsInFlight: Set<UUID> = [],
        resetNotices: [UUID: ResetNotice] = [:]
    ) -> some View {
        AccountsPanel(
            accounts: AccountOrder.grouped(fixture.accounts),
            statuses: fixture.statuses,
            planLabels: fixture.plans,
            now: now,
            resetsInFlight: resetsInFlight,
            resetNotices: resetNotices
        )
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
    }

    /// Hosts the view in a borderless window with the given appearance, lets
    /// SwiftUI settle, and caches its display into a bitmap.
    ///
    /// `legacyScrollers` shows scrollers the way a Mac with a mouse attached
    /// does, taking width from the content; `inspect` sees the settled view.
    private func render<V: View>(
        _ view: V,
        appearance: NSAppearance,
        legacyScrollers: Bool = false,
        inspect: (NSView) -> Void = { _ in }
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer { window.close() }

        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
            if legacyScrollers, let scrollView = Self.scrollView(in: hosting) {
                scrollView.scrollerStyle = .legacy
                scrollView.hasVerticalScroller = true
                scrollView.tile()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        inspect(hosting)
        let bounds = hosting.bounds
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Asserts the render drew something, then writes it when asked to.
    private func check(_ rep: NSBitmapImageRep, named name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, name)
        XCTAssertGreaterThan(distinctColors(in: rep), 16, "\(name) rendered as a flat image")

        guard let directory = ProcessInfo.processInfo.environment["THROTTLE_SNAPSHOT_DIR"], !directory.isEmpty else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func distinctColors(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 200)
        let stepY = max(1, rep.pixelsHigh / 200)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(color.redComponent * 255)
                let g = UInt32(color.greenComponent * 255)
                let b = UInt32(color.blueComponent * 255)
                seen.insert((r << 16) | (g << 8) | b)
                if seen.count > 64 { return seen.count }
            }
        }
        return seen.count
    }
}
