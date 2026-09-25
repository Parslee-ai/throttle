import Foundation
import os
@testable import Throttle

/// A clock the test drives by hand. `sleep(for:)` parks the caller until
/// `advance(by:)` moves time past its deadline, so no polling test waits on
/// wall time. Every sleep request is recorded so tests can assert stagger and
/// timer behaviour by the intervals the scheduler asked for.
///
/// `advance` steps through pending deadlines in order rather than jumping,
/// letting each woken task register its next sleep before the clock moves on.
/// That keeps `now()` truthful inside those tasks: a fetch started after a 2 s
/// stagger sees a time exactly 2 s later than the one before it.
final class TestClock: PollClock, @unchecked Sendable {
    struct RecordedSleep: Equatable {
        let interval: TimeInterval
        let requestedAt: Date
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var recorded: [RecordedSleep] = []
        var cancelledBeforeRegistration: Set<UUID> = []
        /// The deadline of every sleep that parked, by interval, in order.
        var parked: [TimeInterval: [Date]] = [:]
        var parkWaiters: [ParkWaiter] = []
        /// Bumped on every registration, wake, and cancellation; `settle()`
        /// waits for it to stop moving.
        var version = 0
    }

    private struct ParkWaiter {
        let interval: TimeInterval
        let number: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let state: OSAllocatedUnfairLock<State>

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = OSAllocatedUnfairLock(uncheckedState: State(now: start))
    }

    // MARK: PollClock

    func now() -> Date {
        state.withLock { $0.now }
    }

    func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let deadline: Date = state.withLock { s in
            s.recorded.append(RecordedSleep(interval: interval, requestedAt: s.now))
            s.version += 1
            return s.now.addingTimeInterval(interval)
        }
        if interval <= 0 {
            await Task.yield()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (alreadyCancelled, ready): (Bool, [ParkWaiter]) = state.withLock { s in
                    if s.cancelledBeforeRegistration.remove(id) != nil { return (true, []) }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    s.version += 1
                    s.parked[interval, default: []].append(deadline)
                    let count = s.parked[interval]?.count ?? 0
                    let ready = s.parkWaiters.filter { $0.interval == interval && $0.number <= count }
                    s.parkWaiters.removeAll { $0.interval == interval && $0.number <= count }
                    return (false, ready)
                }
                for waiter in ready { waiter.continuation.resume() }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { s in
                if let index = s.sleepers.firstIndex(where: { $0.id == id }) {
                    let sleeper = s.sleepers.remove(at: index)
                    s.version += 1
                    return sleeper.continuation
                }
                s.cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    // MARK: Driving

    /// How many sleeps of `interval` have parked on this clock so far.
    func parkedCount(interval: TimeInterval) -> Int {
        state.withLock { $0.parked[interval]?.count ?? 0 }
    }

    /// Waits until the `number`th sleep of `interval` (1-based, counted
    /// since the clock was made) has parked, and returns its deadline. The
    /// sleep is then waiting on the clock, so advancing to the deadline is
    /// certain to wake it.
    func parkedSleep(interval: TimeInterval, number: Int, file: StaticString = #filePath, line: UInt = #line) async -> Date {
        await awaitEvent("sleep \(number) of \(interval) s parked", file: file, line: line) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked: Bool = self.state.withLock { s in
                    if (s.parked[interval]?.count ?? 0) >= number { return true }
                    s.parkWaiters.append(ParkWaiter(interval: interval, number: number, continuation: continuation))
                    return false
                }
                if parked { continuation.resume() }
            }
        }
        return state.withLock { s in
            let deadlines = s.parked[interval] ?? []
            return number <= deadlines.count ? deadlines[number - 1] : s.now
        }
    }

    /// Every sleep requested so far, in request order.
    var recordedSleeps: [RecordedSleep] {
        state.withLock { $0.recorded }
    }

    /// Sleeps still waiting for the clock to reach their deadline.
    var pendingSleepCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves time forward by `interval`, waking every sleeper whose deadline
    /// falls inside the window, earliest first.
    func advance(by interval: TimeInterval) async {
        await advance(to: now().addingTimeInterval(interval))
    }

    /// Moves time forward to `target`. Does nothing if `target` is in the past.
    func advance(to target: Date) async {
        // Let work already in flight (a cycle that just launched) register its
        // sleeps before time moves, or the clock would jump past them.
        await settle()
        while true {
            let due: [Sleeper]? = state.withLock { s in
                guard let next = s.sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else {
                    return nil
                }
                s.now = max(s.now, next.deadline)
                let woken = s.sleepers.filter { $0.deadline <= s.now }
                s.sleepers.removeAll { $0.deadline <= s.now }
                s.version += 1
                return woken
            }
            guard let due else { break }
            for sleeper in due {
                sleeper.continuation.resume()
            }
            await settle()
        }
        state.withLock { s in
            s.now = max(s.now, target)
        }
        await settle()
    }

    /// Yields until the set of sleepers has been quiet for a while, so tasks
    /// woken by the last step have had the chance to register their next
    /// sleep. Sub-millisecond pauses only; bounded so a stuck task fails the
    /// test instead of hanging it.
    func settle() async {
        var quiet = 0
        var iterations = 0
        while quiet < 20, iterations < 2_000 {
            let before = state.withLock { $0.version }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000)
            iterations += 1
            let after = state.withLock { $0.version }
            if before == after {
                quiet += 1
            } else {
                quiet = 0
            }
        }
    }
}
