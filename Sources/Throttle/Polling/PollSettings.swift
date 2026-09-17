import Foundation

/// User- and test-tunable knobs for the poll scheduler.
///
/// `pollInterval` is the only value the Settings UI exposes. It is clamped to
/// `PollSettings.intervalRange` on construction and on decode, so no code path
/// (a hand-edited preferences file included) can push the cadence under 60 s
/// (ISC-96). The remaining values are fixed by the ISA and exist here so tests
/// can shrink them.
struct PollSettings: Codable, Hashable, Sendable {
    /// Allowed cadence: one minute to thirty minutes.
    static let intervalRange: ClosedRange<TimeInterval> = 60...1_800
    /// Default cadence: five minutes (D-14).
    static let defaultInterval: TimeInterval = 300

    /// Seconds between poll cycles.
    var pollInterval: TimeInterval {
        didSet { pollInterval = Self.clamp(pollInterval) }
    }
    /// Budget for one account: credential resolution plus the usage request.
    /// A fetch still running when it expires is abandoned and the account is
    /// marked stale (ISC-97).
    var perAccountTimeout: TimeInterval
    /// Budget for a whole cycle. Accounts still pending when it expires are
    /// marked stale without a request (ISC-97).
    var cycleDeadline: TimeInterval
    /// A status older than `staleAfterFactor × pollInterval` is stale (ISC-104).
    var staleAfterFactor: Double
    /// Minimum gap between two request starts to the same provider (ISC-96).
    var stagger: TimeInterval

    init(
        pollInterval: TimeInterval = PollSettings.defaultInterval,
        perAccountTimeout: TimeInterval = 15,
        cycleDeadline: TimeInterval = 60,
        staleAfterFactor: Double = 2,
        stagger: TimeInterval = 2
    ) {
        self.pollInterval = Self.clamp(pollInterval)
        self.perAccountTimeout = perAccountTimeout
        self.cycleDeadline = cycleDeadline
        self.staleAfterFactor = staleAfterFactor
        self.stagger = stagger
    }

    /// Age beyond which a cached status renders as stale.
    var staleAfter: TimeInterval {
        staleAfterFactor * pollInterval
    }

    static func clamp(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultInterval }
        return min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case pollInterval, perAccountTimeout, cycleDeadline, staleAfterFactor, stagger
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PollSettings()
        self.init(
            pollInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? defaults.pollInterval,
            perAccountTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .perAccountTimeout) ?? defaults.perAccountTimeout,
            cycleDeadline: try container.decodeIfPresent(TimeInterval.self, forKey: .cycleDeadline) ?? defaults.cycleDeadline,
            staleAfterFactor: try container.decodeIfPresent(Double.self, forKey: .staleAfterFactor) ?? defaults.staleAfterFactor,
            stagger: try container.decodeIfPresent(TimeInterval.self, forKey: .stagger) ?? defaults.stagger
        )
    }
}
