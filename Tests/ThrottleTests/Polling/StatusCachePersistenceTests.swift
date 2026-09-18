import XCTest
@testable import Throttle

/// ISC-90: the last known status survives a relaunch, and nothing secret ever
/// reaches `status-cache.json`.
final class StatusCachePersistenceTests: XCTestCase {
    private var directory: URL!
    private var paths: AppPaths!
    private var clock: TestClock!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottlePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupportDirectory: directory)
        clock = TestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let account = Account(provider: .openai, email: "persist@example.com", sortIndex: 0)

    private func entry(percent: Double, at date: Date, state: AccountState = .ok, plan: String? = "pro") -> CachedStatus {
        let windows = [
            UsageWindow(key: "5h", label: "5h", usedPercent: percent, resetsAt: date.addingTimeInterval(3600), durationSeconds: 18_000),
            UsageWindow(key: "lane:spark-5h", label: "Spark 5h", usedPercent: 12, resetsAt: nil, durationSeconds: 18_000),
        ]
        let status = AccountStatus(
            accountID: account.id,
            provider: account.provider,
            email: account.email,
            windows: windows,
            fetchedAt: date,
            state: state,
            planLabel: plan
        )
        return CachedStatus(status: status, lastGoodWindows: windows, isStale: false, lastAttempt: date, lastError: nil, nextAttemptAt: date.addingTimeInterval(60))
    }

    // MARK: Round trip

    func testEncodeDecodeRoundTripsEveryField() throws {
        let original = entry(percent: 42, at: clock.now(), state: .rateLimited(until: clock.now().addingTimeInterval(120)))
        let data = try StatusCachePersistence.encode([account.id: original])
        let decoded = try StatusCachePersistence.decode(data)
        XCTAssertEqual(decoded, [account.id: original])
    }

    func testEveryAccountStateRoundTrips() throws {
        for state in [AccountState.ok, .needsLogin, .rateLimited(until: clock.now()), .error("Timed out after 15 s"), .forbidden("OAuth authentication is currently not allowed for this organization.")] {
            let original = entry(percent: 10, at: clock.now(), state: state)
            let decoded = try StatusCachePersistence.decode(try StatusCachePersistence.encode([account.id: original]))
            XCTAssertEqual(decoded[account.id]?.status.state, state)
        }
    }

    func testEntriesWithoutASuccessfulFetchAreNotPersisted() throws {
        var never = entry(percent: 0, at: clock.now(), state: .needsLogin)
        never.lastGoodWindows = nil
        let data = try StatusCachePersistence.encode([account.id: never])
        XCTAssertEqual(try StatusCachePersistence.decode(data), [:])
    }

    func testWriteThenLoadAcrossInstancesWithMode0600() async throws {
        let now = clock.now()
        let writer = StatusCachePersistence(paths: paths, clock: clock, minimumWriteInterval: 0)
        await writer.record([account.id: entry(percent: 55, at: now)])

        var info = stat()
        XCTAssertEqual(stat(paths.statusCacheFile.path, &info), 0, "status-cache.json exists")
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let reader = StatusCachePersistence(paths: paths, clock: clock)
        let loaded = await reader.load()
        XCTAssertEqual(loaded[account.id]?.lastGoodWindows?.first?.usedPercent, 55)
        XCTAssertEqual(loaded[account.id]?.status.planLabel, "pro")
        XCTAssertEqual(loaded[account.id]?.status.fetchedAt, now)
    }

    func testMissingOrCorruptFileLoadsAsEmpty() async throws {
        let persistence = StatusCachePersistence(paths: paths, clock: clock)
        let empty = await persistence.load()
        XCTAssertEqual(empty, [:])

        try paths.ensureDirectoryExists()
        try Data("not json".utf8).write(to: paths.statusCacheFile)
        let corrupt = await persistence.load()
        XCTAssertEqual(corrupt, [:])
    }

    // MARK: Debounce

    func testWritesAreDebouncedToOnePerInterval() async throws {
        let persistence = StatusCachePersistence(paths: paths, clock: clock, minimumWriteInterval: 5)
        let t0 = clock.now()
        await persistence.record([account.id: entry(percent: 10, at: t0)])
        await persistence.record([account.id: entry(percent: 20, at: t0)])
        await persistence.record([account.id: entry(percent: 30, at: t0)])

        // The first snapshot is on disk; the newest waits for the floor.
        XCTAssertEqual(try StatusCachePersistence.decode(try Data(contentsOf: paths.statusCacheFile))[account.id]?.lastGoodWindows?.first?.usedPercent, 10)
        await clock.settle()
        XCTAssertEqual(clock.pendingSleepCount, 1, "one deferred write is armed")

        await clock.advance(by: 5)
        await waitUntil("deferred write landed") {
            (try? StatusCachePersistence.decode(try Data(contentsOf: paths.statusCacheFile)))?[account.id]?.lastGoodWindows?.first?.usedPercent == 30
        }
        await persistence.stop()
    }

    func testObserveWritesCacheUpdates() async throws {
        let cache = StatusCache(clock: clock, staleAfter: 600)
        let persistence = StatusCachePersistence(paths: paths, clock: clock, minimumWriteInterval: 0)
        await persistence.observe(cache)
        await cache.recordSuccess(entry(percent: 77, at: clock.now()).status, at: clock.now())
        await waitUntil("cache update persisted") {
            (try? StatusCachePersistence.decode(try Data(contentsOf: paths.statusCacheFile)))?[account.id]?.lastGoodWindows?.first?.usedPercent == 77
        }
        await persistence.stop()
    }

    // MARK: Seeding

    func testSeededEntriesShowUntilTheFirstAttemptAndAgeIntoStale() async throws {
        let cache = StatusCache(clock: clock, staleAfter: 600)
        let fetchedAt = clock.now().addingTimeInterval(-1_000)
        await cache.seed(from: [account.id: entry(percent: 64, at: fetchedAt)])

        let seededEntry = await cache.entry(for: account.id)
        let seeded = try XCTUnwrap(seededEntry)
        XCTAssertEqual(seeded.status.windows.first?.usedPercent, 64)
        XCTAssertTrue(seeded.isStale, "older than staleAfter, so the age rule dims it")
        XCTAssertNil(seeded.nextAttemptAt, "a stale backoff horizon from the previous run is not honoured")

        // A live entry is never overwritten by a seed.
        await cache.recordSuccess(entry(percent: 5, at: clock.now()).status, at: clock.now())
        await cache.seed(from: [account.id: entry(percent: 64, at: fetchedAt)])
        let liveEntry = await cache.entry(for: account.id)
        let live = try XCTUnwrap(liveEntry)
        XCTAssertEqual(live.status.windows.first?.usedPercent, 5)
        XCTAssertFalse(live.isStale)
    }

    // MARK: No secrets

    func testEncodedJSONContainsNoTokenLikeKeys() throws {
        let data = try StatusCachePersistence.encode([account.id: entry(percent: 1, at: clock.now())])
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = Self.allKeys(in: object)
        XCTAssertFalse(keys.isEmpty)
        let pattern = try NSRegularExpression(pattern: "token|secret|refresh", options: [.caseInsensitive])
        for key in keys {
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertNil(pattern.firstMatch(in: key, range: range), "status-cache.json must not carry a key like \(key)")
        }
    }

    private static func allKeys(in value: Any) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.keys.map { $0 } + dictionary.values.flatMap(allKeys)
        case let array as [Any]:
            return array.flatMap(allKeys)
        default:
            return []
        }
    }
}
