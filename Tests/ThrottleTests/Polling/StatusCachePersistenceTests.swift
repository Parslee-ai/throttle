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

    func testResetCreditCountRoundTrips() throws {
        var original = entry(percent: 5, at: clock.now())
        original.status = AccountStatus(
            accountID: original.status.accountID,
            provider: original.status.provider,
            email: original.status.email,
            windows: original.status.windows,
            fetchedAt: original.status.fetchedAt,
            state: .ok,
            planLabel: "pro",
            resetCreditsAvailable: 1
        )
        let decoded = try StatusCachePersistence.decode(try StatusCachePersistence.encode([account.id: original]))
        XCTAssertEqual(decoded[account.id]?.status.resetCreditsAvailable, 1)
        XCTAssertEqual(decoded, [account.id: original])
    }

    /// A cache written before the reset-credit field existed still loads,
    /// with no count rather than a failure.
    func testCacheFromBeforeResetCreditsDecodes() throws {
        let id = account.id.uuidString
        let window = #"{ "durationSeconds" : 604800, "key" : "7d", "label" : "Weekly", "resetsAt" : "2027-01-20T08:00:00Z", "usedPercent" : 33 }"#
        let json = """
        {
          "entries" : {
            "\(id)" : {
              "isStale" : false,
              "lastAttempt" : "2027-01-15T08:00:00Z",
              "lastGoodWindows" : [ \(window) ],
              "status" : {
                "accountID" : "\(id)",
                "email" : "persist@example.com",
                "fetchedAt" : "2027-01-15T08:00:00Z",
                "planLabel" : "pro",
                "provider" : "openai",
                "state" : { "ok" : { } },
                "windows" : [ \(window) ]
              }
            }
          },
          "version" : 1
        }
        """
        let decoded = try StatusCachePersistence.decode(Data(json.utf8))
        let entry = try XCTUnwrap(decoded[account.id])
        XCTAssertNil(entry.status.resetCreditsAvailable)
        XCTAssertEqual(entry.status.planLabel, "pro")
        XCTAssertEqual(entry.status.windows.first?.usedPercent, 33)
        XCTAssertEqual(entry.status.state, .ok)
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

    // MARK: Reset kinds and 0.5.1 compatibility (ISC-484 to ISC-487)

    /// The inputs 0.5.1 encoded into `status-cache-0.5.1.json` and
    /// `status-cache-0.5.1-codex.json`, generated at tag `v0.5.1`.
    private enum V051Inputs {
        static let claudeID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let codexID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let erroredID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let codexOnlyID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        static let readAt = Date(timeIntervalSince1970: 1_793_000_000)

        static func entries() -> [UUID: CachedStatus] {
            let t = readAt
            let claudeWindows = [
                UsageWindow(key: "7d", label: "Weekly", usedPercent: 41, resetsAt: t.addingTimeInterval(200_000), durationSeconds: 604_800),
                UsageWindow(key: "scoped:Testmodel", label: "Testmodel", usedPercent: 100, resetsAt: t.addingTimeInterval(300_000), durationSeconds: 604_800),
            ]
            let claude = CachedStatus(
                status: AccountStatus(accountID: claudeID, provider: .anthropic, email: "fixture-claude", windows: claudeWindows,
                                      fetchedAt: t, state: .ok, planLabel: "max 20x", resetCreditsAvailable: 3),
                lastGoodWindows: claudeWindows, isStale: false, lastAttempt: t, lastError: nil, nextAttemptAt: nil
            )
            let codexWindows = [
                UsageWindow(key: "7d", label: "Weekly", usedPercent: 12.5, resetsAt: t.addingTimeInterval(400_000), durationSeconds: 604_800),
            ]
            let codex = CachedStatus(
                status: AccountStatus(accountID: codexID, provider: .openai, email: "fixture-codex", windows: codexWindows,
                                      fetchedAt: t.addingTimeInterval(-60), state: .rateLimited(until: t.addingTimeInterval(900)),
                                      planLabel: "pro", resetCreditsAvailable: 2),
                lastGoodWindows: codexWindows, isStale: false, lastAttempt: t, lastError: "Rate limited by Codex",
                nextAttemptAt: t.addingTimeInterval(900)
            )
            let erroredWindows = [
                UsageWindow(key: "7d", label: "Weekly", usedPercent: 0, resetsAt: nil, durationSeconds: 604_800),
            ]
            let errored = CachedStatus(
                status: AccountStatus(accountID: erroredID, provider: .anthropic, email: "fixture-claude-two", windows: erroredWindows,
                                      fetchedAt: t.addingTimeInterval(-3_600), state: .error("Timed out after 15 s"),
                                      planLabel: nil, resetCreditsAvailable: nil),
                lastGoodWindows: erroredWindows, isStale: true, lastAttempt: t, lastError: "Timed out after 15 s",
                nextAttemptAt: t.addingTimeInterval(120)
            )
            return [claudeID: claude, codexID: codex, erroredID: errored]
        }

        static func codexOnly() -> [UUID: CachedStatus] {
            let t = readAt
            let windows = [
                UsageWindow(key: "7d", label: "Weekly", usedPercent: 63, resetsAt: t.addingTimeInterval(500_000), durationSeconds: 604_800),
                UsageWindow(key: "lane:spark-7d", label: "Spark Weekly", usedPercent: 4, resetsAt: nil, durationSeconds: 604_800),
            ]
            let entry = CachedStatus(
                status: AccountStatus(accountID: codexOnlyID, provider: .openai, email: "fixture-codex-two", windows: windows,
                                      fetchedAt: t, state: .ok, planLabel: "plus", resetCreditsAvailable: 1),
                lastGoodWindows: windows, isStale: false, lastAttempt: t, lastError: nil, nextAttemptAt: nil
            )
            return [codexOnlyID: entry]
        }
    }

    private static let allReasonKinds: [ResetKind] = [
        ResetKind(key: .full, label: "Full reset", count: 2),
        ResetKind(key: .weekly, label: "7-day reset", count: 1, reason: .cooldown(until: Date(timeIntervalSince1970: 1_793_000_600))),
        ResetKind(key: .session, label: "5-hour reset", count: 0),
        ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1, reason: .nothingToGiveBack),
        ResetKind(key: .other, label: "", count: 1, reason: .notStarted(startsAt: Date(timeIntervalSince1970: 1_793_086_400))),
    ]

    /// The 0.5.1 Claude entry as the new build writes it: the same reading
    /// with kinds.
    private func newBuildEntries() -> [UUID: CachedStatus] {
        var entries = V051Inputs.entries()
        let claude = entries[V051Inputs.claudeID]!
        entries[V051Inputs.claudeID]?.status = AccountStatus(
            accountID: claude.status.accountID,
            provider: claude.status.provider,
            email: claude.status.email,
            windows: claude.status.windows,
            fetchedAt: claude.status.fetchedAt,
            state: claude.status.state,
            planLabel: claude.status.planLabel,
            resetKinds: Self.allReasonKinds
        )
        return entries
    }

    func testKindsRoundTripThroughTheCacheFile() throws {
        let entries = newBuildEntries()
        let decoded = try StatusCachePersistence.decode(try StatusCachePersistence.encode(entries))
        XCTAssertEqual(decoded, entries)
        let kinds = try XCTUnwrap(decoded[V051Inputs.claudeID]?.status.resetKinds)
        XCTAssertEqual(kinds.map(\.key), [.full, .weekly, .session, .modelRefill, .other])
        XCTAssertEqual(kinds.map(\.label), ["Full reset", "7-day reset", "5-hour reset", "Testmodel reset", "Reset"])
        XCTAssertEqual(kinds.map(\.count), [2, 1, 0, 1, 1])
        XCTAssertEqual(kinds.map(\.reason), [
            nil, .cooldown(until: Date(timeIntervalSince1970: 1_793_000_600)), .noneLeft, .nothingToGiveBack,
            .notStarted(startsAt: Date(timeIntervalSince1970: 1_793_086_400)),
        ])
        XCTAssertEqual(decoded[V051Inputs.claudeID]?.status.resetCreditsAvailable, 5)
    }

    func testKindsRoundTripThroughSaveAndLoad() async throws {
        let persistence = StatusCachePersistence(paths: paths, clock: clock, minimumWriteInterval: 0)
        let entries = newBuildEntries()
        await persistence.record(entries)
        let loaded = await StatusCachePersistence(paths: paths, clock: clock).load()
        XCTAssertEqual(loaded, entries)
    }

    func testDecodesV051CacheWithTheSameWindowsPlanAndTotalAndNoKinds() throws {
        let decoded = try StatusCachePersistence.decode(try TestFixtures.data("status-cache-0.5.1"))
        let expected = V051Inputs.entries()
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.count, 3)
        for (id, entry) in decoded {
            XCTAssertEqual(entry.status.windows, expected[id]?.status.windows)
            XCTAssertEqual(entry.status.planLabel, expected[id]?.status.planLabel)
            XCTAssertEqual(entry.status.resetCreditsAvailable, expected[id]?.status.resetCreditsAvailable)
            XCTAssertNil(entry.status.resetKinds)
        }
        XCTAssertEqual(decoded[V051Inputs.claudeID]?.status.resetCreditsAvailable, 3)
    }

    /// A downgrade never blanks the rows: what the new build writes, kinds
    /// and all, loads in 0.5.1's own types with every entry intact.
    func testDowngradeDecodesInV051Types() throws {
        XCTAssertEqual(StatusCachePersistence.formatVersion, 1)
        XCTAssertEqual(StatusCachePersistence.formatVersion, V051.formatVersion)
        let written = newBuildEntries()
        let data = try StatusCachePersistence.encode(written)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("resetKinds"), "the file under test carries kinds")

        let old = try V051.decode(data)
        XCTAssertEqual(Set(old.keys), Set(written.keys), "every entry survives")
        for (id, entry) in written {
            let downgraded = try XCTUnwrap(old[id])
            XCTAssertEqual(downgraded.status.accountID, entry.status.accountID)
            XCTAssertEqual(downgraded.status.provider.rawValue, entry.status.provider.rawValue)
            XCTAssertEqual(downgraded.status.email, entry.status.email)
            XCTAssertEqual(downgraded.status.fetchedAt, entry.status.fetchedAt)
            XCTAssertEqual(downgraded.status.planLabel, entry.status.planLabel)
            XCTAssertEqual(downgraded.status.resetCreditsAvailable, entry.status.resetCreditsAvailable, "the total survives")
            XCTAssertEqual(downgraded.status.windows.map(\.key), entry.status.windows.map(\.key))
            XCTAssertEqual(downgraded.status.windows.map(\.usedPercent), entry.status.windows.map(\.usedPercent))
            XCTAssertEqual(downgraded.status.windows.map(\.resetsAt), entry.status.windows.map(\.resetsAt))
            XCTAssertEqual(downgraded.lastGoodWindows?.count, entry.lastGoodWindows?.count)
            XCTAssertEqual(downgraded.isStale, entry.isStale)
            XCTAssertEqual(downgraded.lastAttempt, entry.lastAttempt)
            XCTAssertEqual(downgraded.lastError, entry.lastError)
            XCTAssertEqual(downgraded.nextAttemptAt, entry.nextAttemptAt)
            XCTAssertEqual(String(describing: downgraded.status.state), String(describing: entry.status.state), "the state survives")
        }
        XCTAssertEqual(old[V051Inputs.claudeID]?.status.resetCreditsAvailable, 5)
    }

    func testCodexBytesUnchangedFromV051() throws {
        let expected = try TestFixtures.data("status-cache-0.5.1-codex")
        XCTAssertEqual(try StatusCachePersistence.encode(V051Inputs.codexOnly()), expected)
        XCTAssertEqual(try StatusCachePersistence.encode(V051Inputs.entries()), try TestFixtures.data("status-cache-0.5.1"),
                       "a status with no kinds encodes as 0.5.1 did")
    }
}
