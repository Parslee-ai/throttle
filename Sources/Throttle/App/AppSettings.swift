import Foundation
import Observation

/// Non-secret per-account display metadata the status model does not carry,
/// such as the plan badge learned at login (ISC-117). Lives in UserDefaults,
/// never in `accounts.json` and never in the Keychain.
struct AccountMeta: Codable, Hashable, Sendable {
    var planLabel: String?
}

/// User preferences, backed by `UserDefaults` (ISC-126).
///
/// Every numeric setting is clamped on the way in, so a hand-edited plist can
/// not push the poll cadence under a minute or the rotation under five
/// seconds. Nothing secret is ever stored here.
@MainActor
@Observable
final class AppSettings {
    static let pollIntervalRange: ClosedRange<TimeInterval> = PollSettings.intervalRange
    static let rotationIntervalRange: ClosedRange<TimeInterval> = 5...60
    static let defaultRotationInterval: TimeInterval = 10

    enum Key {
        static let pollInterval = "pollInterval"
        static let rotationInterval = "rotationInterval"
        static let launchAtLogin = "launchAtLogin"
        static let accountMeta = "accountMeta"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // Clamping lives in explicit setters over private storage. A `didSet` that
    // reassigns its own property re-enters the `@Observable` setter and never
    // returns.
    private var pollIntervalStorage: TimeInterval
    private var rotationIntervalStorage: TimeInterval

    /// Seconds between poll cycles. Default 300, clamped to 60…1800.
    var pollInterval: TimeInterval {
        get { pollIntervalStorage }
        set {
            pollIntervalStorage = Self.clamp(newValue, to: Self.pollIntervalRange, default: PollSettings.defaultInterval)
            defaults.set(pollIntervalStorage, forKey: Key.pollInterval)
        }
    }

    /// Seconds each account stays in the menu bar. Default 10, clamped to 5…60.
    var rotationInterval: TimeInterval {
        get { rotationIntervalStorage }
        set {
            rotationIntervalStorage = Self.clamp(newValue, to: Self.rotationIntervalRange, default: Self.defaultRotationInterval)
            defaults.set(rotationIntervalStorage, forKey: Key.rotationInterval)
        }
    }

    /// The user's last choice for launch at login. The system's answer is
    /// `SMAppService.mainApp.status`; `AppModel` reconciles the two.
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    /// Display metadata keyed by account id.
    var accountMeta: [UUID: AccountMeta] {
        didSet { persistAccountMeta() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPoll = defaults.object(forKey: Key.pollInterval) as? Double
        pollIntervalStorage = Self.clamp(storedPoll ?? PollSettings.defaultInterval, to: Self.pollIntervalRange, default: PollSettings.defaultInterval)
        let storedRotation = defaults.object(forKey: Key.rotationInterval) as? Double
        rotationIntervalStorage = Self.clamp(storedRotation ?? Self.defaultRotationInterval, to: Self.rotationIntervalRange, default: Self.defaultRotationInterval)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        accountMeta = Self.loadAccountMeta(from: defaults)
    }

    /// The scheduler's view of these settings.
    var pollSettings: PollSettings {
        PollSettings(pollInterval: pollInterval)
    }

    func planLabel(for id: UUID) -> String? {
        accountMeta[id]?.planLabel
    }

    func setPlanLabel(_ label: String?, for id: UUID) {
        var meta = accountMeta[id] ?? AccountMeta()
        meta.planLabel = label
        accountMeta[id] = meta
    }

    func removeMeta(for id: UUID) {
        accountMeta[id] = nil
    }

    // MARK: Helpers

    static func clamp(_ value: TimeInterval, to range: ClosedRange<TimeInterval>, default fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func loadAccountMeta(from defaults: UserDefaults) -> [UUID: AccountMeta] {
        guard let data = defaults.data(forKey: Key.accountMeta),
              let decoded = try? JSONDecoder().decode([String: AccountMeta].self, from: data) else {
            return [:]
        }
        var result: [UUID: AccountMeta] = [:]
        for (key, value) in decoded {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    private func persistAccountMeta() {
        var encodable: [String: AccountMeta] = [:]
        for (id, meta) in accountMeta { encodable[id.uuidString] = meta }
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Key.accountMeta)
        }
    }
}
