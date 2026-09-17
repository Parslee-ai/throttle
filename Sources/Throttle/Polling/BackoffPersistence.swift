import Foundation
import os

/// Carries the provider-wide rate-limit horizon across relaunches (ISC-99).
///
/// Anthropic answers a 429 with a `Retry-After` that can run an hour, and
/// every further request inside that window extends it. With the horizon
/// held only in memory, each relaunch, and each "Add account" (which calls
/// `refreshNow`), ran an immediate cycle, hit the endpoint again, and pushed
/// the horizon out. So the scheduler writes the active provider horizons here
/// whenever they change and seeds `BackoffPolicy` from them before its first
/// cycle.
///
/// The file is `rate-limits.json` next to `status-cache.json`: a JSON object
/// whose keys are `Provider.rawValue` and whose values are ISO-8601 dates.
/// Nothing else is ever written to it. It is written atomically with mode
/// 0600 like every other file under `AppPaths`. An unreadable file is logged
/// and treated as empty; the next write replaces it.
struct BackoffPersistence: Sendable {
    private let paths: AppPaths
    private let logger = Logger(subsystem: "ai.parslee.throttle", category: "BackoffPersistence")

    init(paths: AppPaths) {
        self.paths = paths
    }

    /// The horizons from the previous run, expired ones included: the policy
    /// drops those when it is seeded. Empty when there is no file.
    func load() -> [Provider: Date] {
        let url = paths.rateLimitsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try Self.decode(try Data(contentsOf: url))
        } catch {
            logger.error("Ignoring unreadable rate-limit file: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// Replaces the file with these horizons. An empty map writes `{}` so a
    /// cleared horizon does not come back on the next launch.
    func save(_ horizons: [Provider: Date]) {
        do {
            try paths.ensureDirectoryExists()
            try AccountStore.atomicWrite(try Self.encode(horizons), to: paths.rateLimitsFile)
        } catch {
            logger.error("Could not write the rate-limit file: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Encoding

    static func encode(_ horizons: [Provider: Date]) throws -> Data {
        var keyed: [String: Date] = [:]
        for (provider, until) in horizons {
            keyed[provider.rawValue] = until
        }
        return try encoder.encode(keyed)
    }

    /// Keys that are not a known provider are skipped rather than failing the
    /// whole file, so a provider removed in a later build cannot poison it.
    static func decode(_ data: Data) throws -> [Provider: Date] {
        let keyed = try decoder.decode([String: Date].self, from: data)
        var result: [Provider: Date] = [:]
        for (key, until) in keyed {
            guard let provider = Provider(rawValue: key) else { continue }
            result[provider] = until
        }
        return result
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
