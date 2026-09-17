import XCTest
@testable import Throttle

@MainActor
final class RotationControllerTests: XCTestCase {
    private func accounts(_ count: Int) -> [Account] {
        (0..<count).map { UIFixtures.account("user\($0)@example.com", sortIndex: $0) }
    }

    func testAdvancesInOrderAndWraps() {
        let list = accounts(3)
        let controller = RotationController(accounts: list, statuses: [:])
        XCTAssertEqual(controller.current?.id, list[0].id)
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[1].id)
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[2].id)
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[0].id, "wraps to the first account")
    }

    func testPauseHoldsTheCurrentAccountAndResumesOnNextTick() {
        let list = accounts(2)
        let controller = RotationController(accounts: list, statuses: [:])
        controller.isPaused = true
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[0].id)
        controller.isPaused = false
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[1].id)
    }

    func testEmptyAndSingleAccountNeverMove() {
        let empty = RotationController()
        empty.tick()
        XCTAssertNil(empty.current)

        let list = accounts(1)
        let single = RotationController(accounts: list, statuses: [:])
        single.tick()
        XCTAssertEqual(single.current?.id, list[0].id)
    }

    func testReplacingAccountsKeepsTheCurrentOneInPlace() {
        let list = accounts(3)
        let controller = RotationController(accounts: list, statuses: [:])
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.current?.id, list[2].id)
        controller.setAccounts([list[2], list[0]])
        XCTAssertEqual(controller.current?.id, list[2].id)
        controller.setAccounts([list[0]])
        XCTAssertEqual(controller.current?.id, list[0].id)
    }

    /// ISC-103: rotation reads cached data only. The controller is built over
    /// a static dictionary with a counting provider alive beside it, and one
    /// hundred ticks leave the provider's fetch count at zero.
    func testOneHundredTicksIssueNoFetch() {
        let clock = TestClock()
        let provider = MockUsageProvider(provider: .anthropic, clock: clock)
        let list = accounts(4)
        var statuses: [UUID: CachedStatus] = [:]
        for account in list {
            statuses[account.id] = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 50)])
        }
        let controller = RotationController(accounts: list, statuses: statuses)
        for _ in 0..<100 {
            controller.tick()
            _ = controller.currentStatus
            _ = controller.current.map {
                Formatting.barLabel(account: $0, cached: controller.statuses[$0.id], showRemaining: false, now: UIFixtures.now)
            }
        }
        XCTAssertEqual(controller.current?.id, list[0].id, "100 ticks over 4 accounts lands back on the first")
        XCTAssertEqual(provider.fetchCount, 0)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testTimerTicksOnTheConfiguredInterval() async throws {
        let list = accounts(3)
        let ticks = TickGate()
        let controller = RotationController(accounts: list, statuses: [:], interval: 10) { seconds in
            await ticks.record(seconds)
            try await ticks.waitForRelease()
        }
        controller.start()
        await ticks.release()
        await ticks.release()
        try await Task.sleep(for: .milliseconds(50))
        controller.stop()
        let intervals = await ticks.intervals
        XCTAssertEqual(intervals.prefix(2), [10, 10])
        XCTAssertEqual(controller.current?.id, list[2].id)
    }
}

/// Lets a test drive the controller's sleep by hand.
private actor TickGate {
    private(set) var intervals: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var pendingReleases = 0

    func record(_ seconds: TimeInterval) {
        intervals.append(seconds)
    }

    func waitForRelease() async throws {
        if pendingReleases > 0 {
            pendingReleases -= 1
            return
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() async {
        if waiters.isEmpty {
            pendingReleases += 1
        } else {
            waiters.removeFirst().resume()
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
}
