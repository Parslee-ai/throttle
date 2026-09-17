import Foundation
import os

/// Keeps the last known status of every account on disk so a relaunch shows
/// the previous numbers, dimmed by age, instead of blank rows (ISC-90).
///
/// What lands in `status-cache.json` is `CachedStatus` only: account id,
/// provider, email, windows, timestamps, state, plan badge. No credential type
/// is reachable from `CachedStatus`, so no token can be written here; the test
/// suite asserts the encoded keys against a token/secret pattern as well.
///
/// Writes are debounced to at most one per `minimumWriteInterval`: the cache
/// publishes after every account in a cycle, and one write at the end of the
/// burst is enough. The file is written atomically with mode 0600, like
/// `accounts.json`.
actor StatusCachePersistence {
    /// Format marker so a future shape change can discard an old file cleanly.
    static let formatVersion = 1
    /// Default floor between two writes.
    static let defaultMinimumWriteInterval: TimeInterval = 5

    private struct Payload: Codable {
        var version: Int
        var entries: [String: CachedStatus]
    }

    private let paths: AppPaths
    private let clock: any PollClock
    private let minimumWriteInterval: TimeInterval
    private let logger = Logger(subsystem: "ai.parslee.throttle", category: "StatusCachePersistence")

    private var latest: [UUID: CachedStatus]?
    private var lastWriteAt: Date?
    private var pendingWrite: Task<Void, Never>?
    private var observer: Task<Void, Never>?

    init(
        paths: AppPaths,
        clock: any PollClock = SystemClock(),
        minimumWriteInterval: TimeInterval = StatusCachePersistence.defaultMinimumWriteInterval
    ) {
        self.paths = paths
        self.clock = clock
        self.minimumWriteInterval = minimumWriteInterval
    }

    // MARK: Loading

    /// The entries from the previous run, or an empty map when there is no
    /// file. A file that fails to decode is logged and treated as empty; it is
    /// overwritten by the next write, because it is a cache, not a record.
    func load() -> [UUID: CachedStatus] {
        let url = paths.statusCacheFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decode(data)
        } catch {
            logger.error("Ignoring unreadable status cache: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    // MARK: Observing

    /// Follows the cache's updates and writes each snapshot, debounced. Stops
    /// when `stop()` is called or the stream ends.
    func observe(_ cache: StatusCache) {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            for await snapshot in await cache.updates() {
                guard let self else { return }
                await self.record(snapshot)
            }
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
        pendingWrite?.cancel()
        pendingWrite = nil
    }

    /// Notes a new snapshot and writes it now when the floor has passed, or
    /// schedules one write for when it does. Later snapshots inside the window
    /// replace the pending one; only the newest is written.
    func record(_ snapshot: [UUID: CachedStatus]) {
        latest = snapshot
        guard pendingWrite == nil else { return }
        let now = clock.now()
        if let lastWriteAt, now.timeIntervalSince(lastWriteAt) < minimumWriteInterval {
            let wait = minimumWriteInterval - now.timeIntervalSince(lastWriteAt)
            pendingWrite = Task { [weak self, clock] in
                do {
                    try await clock.sleep(for: wait)
                } catch {
                    return
                }
                await self?.flush()
            }
        } else {
            writeLatest()
        }
    }

    /// Writes the newest snapshot immediately, if one is waiting.
    func flush() {
        pendingWrite = nil
        writeLatest()
    }

    // MARK: Encoding

    /// Only accounts with at least one successful reading are kept; an entry
    /// that never succeeded has nothing worth showing on relaunch.
    static func encode(_ entries: [UUID: CachedStatus]) throws -> Data {
        var keyed: [String: CachedStatus] = [:]
        for (id, entry) in entries where entry.lastGoodWindows != nil {
            keyed[id.uuidString] = entry
        }
        return try encoder.encode(Payload(version: formatVersion, entries: keyed))
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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Writing

    private func writeLatest() {
        guard let snapshot = latest else { return }
        latest = nil
        lastWriteAt = clock.now()
        do {
            let data = try Self.encode(snapshot)
            try paths.ensureDirectoryExists()
            try AccountStore.atomicWrite(data, to: paths.statusCacheFile)
        } catch {
            logger.error("Could not write the status cache: \(String(describing: error), privacy: .public)")
        }
    }
}
