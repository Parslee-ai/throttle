import Foundation

/// A frozen copy of the types Throttle 0.5.1 decodes `status-cache.json`
/// with, taken from tag `v0.5.1`: `AccountStatus` (Models/AccountStatus.swift),
/// `AccountState` (Models/AccountState.swift), `Provider`'s raw values
/// (Models/Provider.swift), `UsageWindow` (Models/UsageWindow.swift),
/// `CachedStatus` (Polling/StatusCache.swift), and the payload and decode step
/// of `StatusCachePersistence` (Polling/StatusCachePersistence.swift). Stored
/// properties, cases and coding are verbatim; doc comments and members that
/// play no part in decoding are left out.
///
/// Never edit these to match the app: they are what an installed 0.5.1 does
/// with a file the new build wrote, so a downgrade test that fails here
/// means a downgrade would blank the rows.
enum V051 {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case anthropic
        case openai
    }

    enum AccountState: Codable, Hashable, Sendable {
        case ok
        case needsLogin
        case rateLimited(until: Date)
        case forbidden(String)
        case error(String)
    }

    struct UsageWindow: Codable, Hashable, Sendable {
        let key: String
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
        let durationSeconds: Int
    }

    struct AccountStatus: Codable, Hashable, Sendable {
        let accountID: UUID
        let provider: Provider
        let email: String
        let windows: [UsageWindow]
        let fetchedAt: Date
        let state: AccountState
        let planLabel: String?
        let resetCreditsAvailable: Int?
    }

    struct CachedStatus: Codable, Hashable, Sendable {
        var status: AccountStatus
        var lastGoodWindows: [UsageWindow]?
        var isStale: Bool
        var lastAttempt: Date
        var lastError: String?
        var nextAttemptAt: Date?
    }

    static let formatVersion = 1

    private struct Payload: Codable {
        var version: Int
        var entries: [String: CachedStatus]
    }

    static func decode(_ data: Data) throws -> [UUID: CachedStatus] {
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.version == formatVersion else { return [:] }
        var result: [UUID: CachedStatus] = [:]
        for (key, entry) in payload.entries {
            guard let id = UUID(uuidString: key), id == entry.status.accountID else { continue }
            result[id] = entry
        }
        return result
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
