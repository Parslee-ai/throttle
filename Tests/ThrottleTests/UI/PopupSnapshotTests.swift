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

    // MARK: Rendering

    private static let appearances: [(name: String, value: NSAppearance)] = [
        ("dark", NSAppearance(named: .darkAqua)!),
        ("light", NSAppearance(named: .aqua)!),
    ]

    private func panel(for fixture: Fixture) -> some View {
        AccountsPanel(
            accounts: AccountOrder.grouped(fixture.accounts),
            statuses: fixture.statuses,
            planLabels: fixture.plans,
            now: now
        )
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
    }

    /// Hosts the view in a borderless window with the given appearance, lets
    /// SwiftUI settle, and caches its display into a bitmap.
    private func render<V: View>(_ view: V, appearance: NSAppearance) throws -> NSBitmapImageRep {
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
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
