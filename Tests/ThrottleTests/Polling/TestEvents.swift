import Foundation
import Observation
import os
import XCTest

/// How long an event wait may stay pending before the test fails instead of
/// hanging the suite. It is a deadlock detector, not a synchronization
/// mechanism: every wait below resumes on the exact event it names, and no
/// passing run comes anywhere near this.
let deadlockGuard: Duration = .seconds(60)

/// Suspends until `event` returns. `event` must wait on an explicit signal
/// (a continuation resumed by the code under test or its stub), never on
/// wall time. A wait still pending after `deadlockGuard` fails the test.
func awaitEvent(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ event: @escaping @Sendable () async -> Void
) async {
    var watchdog: Task<Void, Never>?
    let happened: Bool = await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task {
            await event()
            once.resume(true)
        }
        watchdog = Task {
            try? await Task.sleep(for: deadlockGuard)
            once.resume(false)
        }
    }
    watchdog?.cancel()
    if !happened {
        XCTFail("Deadlocked waiting for \(description)", file: file, line: line)
    }
}

/// Resumes a continuation once; later calls are ignored.
final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ value: T) {
        let pending = continuation.withLock { stored -> CheckedContinuation<T, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}

/// A gate the test opens by hand. Every `wait()` before `open()` suspends
/// until it; every one after returns at once. Counts the waits, so a test can
/// prove how many callers reached it.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waits = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open: Bool = state.withLock { s in
                s.waits += 1
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// How many callers have reached the gate so far.
    var waits: Int { state.withLock { $0.waits } }
}

/// Returns once `condition` holds, re-checking it only when an observable
/// property it read changes. Every read and write happens on the main actor,
/// so no change can slip between a check and the next registration.
@MainActor
func observeUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}
