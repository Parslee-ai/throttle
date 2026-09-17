import Foundation

/// The scheduler's only source of time.
///
/// Named `PollClock` rather than `Clock` so it never collides with
/// `Swift.Clock` in files that see both (the test target imports Throttle
/// with `@testable` next to the standard library). Production uses
/// `SystemClock`; tests use a manual clock so no test waits on wall time.
protocol PollClock: Sendable {
    /// The current time.
    func now() -> Date
    /// Suspends for `interval` seconds. Throws `CancellationError` when the
    /// calling task is cancelled before the interval elapses.
    func sleep(for interval: TimeInterval) async throws
}

/// Wall-clock time backed by `Task.sleep`.
struct SystemClock: PollClock {
    /// Longest single sleep honoured, one year, so a huge interval can never
    /// overflow the nanosecond conversion.
    private static let maximumSleep: TimeInterval = 365 * 86_400

    func now() -> Date {
        Date()
    }

    func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            try Task.checkCancellation()
            return
        }
        let clamped = min(interval, Self.maximumSleep)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}
