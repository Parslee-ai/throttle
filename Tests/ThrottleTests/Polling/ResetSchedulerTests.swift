import XCTest
@testable import Throttle

/// The scheduler's reset path against `MockUsageProvider`: it is reached only
/// by an explicit call, never by polling; it is single-flight per account; a
/// 401 forces one refresh and resends the same attempt; a 429 leaves the poll
/// backoff alone; and the follow-up read touches only that account, honours
/// backoff, and never resurrects a removed row.
final class ResetSchedulerTests: XCTestCase {
    private var fixtures: [PollingFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        fixtures = []
    }

    private func makeFixture(refreshingTokens: Bool = false) -> PollingFixture {
        let fixture = PollingFixture(refreshingTokens: refreshingTokens)
        fixtures.append(fixture)
        return fixture
    }

    private var totalResets: (PollingFixture) -> Int {
        { $0.anthropic.resetCount + $0.openai.resetCount }
    }

    /// Runs one cycle, then stops the timer so only the reset path can issue
    /// requests for the rest of the test.
    private func pollOnceThenStop(_ f: PollingFixture) async {
        await f.scheduler.start()
        // Past the stagger between same-provider accounts, short of the timer.
        await f.clock.advance(by: 10)
        await f.waitForCycles(1)
        await f.scheduler.stop()
    }

    // MARK: Polling never spends

    func testPollCyclesRefreshNowAndWakeNeverSendAReset() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        try await f.addAccount(.openai)
        f.anthropic.setResetCredits(2)
        f.openai.setResetCredits(2)

        await f.scheduler.start()
        await f.waitForCycles(1)
        for cycle in 2...4 {
            await f.clock.advance(by: 300)
            await f.waitForCycles(cycle)
        }
        await f.scheduler.refreshNow()
        await f.waitForCycles(5)
        await f.scheduler.handleWillSleep()
        await f.scheduler.handleDidWake()
        await f.waitForCycles(6)

        XCTAssertEqual(f.totalFetches, 12, "six cycles over two accounts")
        XCTAssertEqual(totalResets(f), 0, "no cycle, refresh or wake ever spends a reset")
    }

    // MARK: Single-flight per account

    func testASecondResetWhileOneRunsSendsNothing() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.scriptResets([.hang], for: account)

        let first = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await waitUntil("first reset sent") { f.openai.resetCount == 1 }

        let second = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(f.openai.resetCount, 1, "the second attempt sent nothing")

        // The first attempt is bounded: its timeout ends it as unreachable.
        await f.clock.advance(by: PollScheduler.resetTimeout)
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .unreachable)
        let running = await f.scheduler.isResetInFlight(account.id)
        XCTAssertFalse(running, "the account can be reset again after the timeout")
        XCTAssertEqual(f.openai.fetchCount, 0, "a reset that never answered triggers no read")
    }

    func testResetsOnTwoAccountsRunSideBySide() async throws {
        let f = makeFixture()
        let a = try await f.addAccount(.openai)
        let b = try await f.addAccount(.openai)
        f.openai.scriptResets([.waitThenAnswer(.nothingToReset)], for: a)
        f.openai.scriptResets([.answer(.nothingToReset)], for: b)

        let first = Task { await f.scheduler.useReset(accountID: a.id, attemptID: UUID()) }
        await waitUntil("a's reset sent") { f.openai.resetCount == 1 }
        let other = await f.scheduler.useReset(accountID: b.id, attemptID: UUID())
        XCTAssertEqual(other, .outcome(.nothingToReset), "b is not locked by a's run")
        f.openai.releaseResets()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .outcome(.nothingToReset))
    }

    // MARK: Auth

    func testNeedsLoginForcesOneRefreshAndResendsTheSameAttempt() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.openai)
        f.openai.scriptResets([.fail(.needsLogin), .answer(.nothingToReset)], for: account)
        let attemptID = UUID()

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: attemptID)

        XCTAssertEqual(result, .outcome(.nothingToReset))
        XCTAssertEqual(f.openai.refreshCount, 1, "exactly one forced refresh")
        XCTAssertEqual(f.openai.resetCalls.map(\.attemptID), [attemptID, attemptID], "the resend carries the same attempt id")
        let tokens = f.openai.resetCalls.map(\.accessToken)
        XCTAssertNotEqual(tokens.first, tokens.last, "the resend used the refreshed token")
        let entry = await f.entry(account)
        XCTAssertNil(entry, "nothing-to-reset writes nothing and reads nothing")
    }

    func testSecondNeedsLoginFlagsTheAccountAndKeepsTheRow() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setBehavior(.succeed(usedPercent: 40), for: account)
        await pollOnceThenStop(f)
        f.anthropic.scriptResets([.fail(.needsLogin)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .needsLogin)
        XCTAssertEqual(f.anthropic.refreshCount, 1)
        XCTAssertEqual(f.anthropic.resetCount, 2, "sent once, resent once, never a third time")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.state, .needsLogin)
        XCTAssertEqual(entry.lastGoodWindows?.first?.usedPercent, 40, "last good numbers kept, dimmed")
        let stored = await f.store.accounts().map(\.id)
        XCTAssertEqual(stored, [account.id], "the row is never deleted")
        XCTAssertEqual(f.anthropic.fetchCount, 1, "no read after a sign-in failure")
    }

    func testAResetAndAPollOnAnExpiringTokenRefreshOnce() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.openai)
        f.openai.scriptResets([.answer(.nothingToReset)], for: account)
        try await f.store.updateCredential(
            AccountCredential(accessToken: "expiring", refreshToken: "refresh", expiresAt: f.clock.now()),
            for: account.id
        )

        async let reset = f.scheduler.useReset(accountID: account.id, attemptID: UUID())
        async let poll: Void = f.scheduler.refreshNow()
        let (result, _) = await (reset, poll)
        await f.waitForCycles(1)

        XCTAssertEqual(result, .outcome(.nothingToReset))
        XCTAssertEqual(f.openai.refreshCount, 1, "one refresh shared by the reset and the poll")
        XCTAssertEqual(f.openai.resetCalls.map(\.accessToken), ["expiring-r1"], "the reset used the rotated token")
        let stored = try await f.store.credential(for: account.id)
        XCTAssertEqual(stored?.accessToken, "expiring-r1", "the rotated pair was written back")
    }

    // MARK: Rate limit

    func testRateLimitOnTheResetLeavesThePollBackoffAlone() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        await pollOnceThenStop(f)
        let before = try await f.requireEntry(account)
        f.anthropic.scriptResets([.fail(.rateLimited(retryAfter: 600))], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .rateLimited(until: f.clock.now().addingTimeInterval(600)))
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after, before, "the row's reading and state are untouched")

        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the next poll is not skipped: no horizon was armed")
    }

    // MARK: The read after a reset

    func testSuccessReadsThatOneAccountOnceAndLeavesOthersAlone() async throws {
        let f = makeFixture()
        let target = try await f.addAccount(.openai)
        let sibling = try await f.addAccount(.openai)
        let other = try await f.addAccount(.anthropic)
        f.openai.setBehavior(.succeed(usedPercent: 70), for: target)
        await pollOnceThenStop(f)
        let siblingBefore = try await f.requireEntry(sibling)
        let otherBefore = try await f.requireEntry(other)
        f.openai.setBehavior(.succeed(usedPercent: 0), for: target)
        f.openai.scriptResets([.answer(.reset)], for: target)

        let result = await f.scheduler.useReset(accountID: target.id, attemptID: UUID())

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.openai.fetchCount(for: target), 2, "exactly one read after the reset")
        XCTAssertEqual(f.openai.fetchCount(for: sibling), 1)
        XCTAssertEqual(f.anthropic.fetchCount(for: other), 1)
        let targetAfter = try await f.requireEntry(target)
        XCTAssertEqual(targetAfter.status.windows.first?.usedPercent, 0, "the fresh reading, not a guess")
        let siblingAfter = try await f.requireEntry(sibling)
        let otherAfter = try await f.requireEntry(other)
        XCTAssertEqual(siblingAfter, siblingBefore)
        XCTAssertEqual(otherAfter, otherBefore)
    }

    func testAnswersThatChangeTheCountReadOnceAndTheOthersDoNot() async throws {
        let cases: [(MockUsageProvider.ResetBehavior, Int)] = [
            (.answer(.noCredit), 1),
            (.answer(.notAvailable), 1),
            (.answer(.unexpected), 1),
            (.fail(.invalidResponse("unparseable")), 1),
            (.fail(.tooLarge), 1),
            (.answer(.nothingToReset), 0),
            (.answer(.cooldown(until: nil)), 0),
            (.fail(.httpStatus(503)), 1),
            (.fail(.httpStatus(500)), 1),
            (.fail(.httpStatus(404)), 0),
            (.fail(.forbidden(reason: "no")), 0),
            (.fail(.transport(URLError(.notConnectedToInternet))), 0),
        ]
        for (behavior, reads) in cases {
            let f = makeFixture()
            let account = try await f.addAccount(.openai)
            f.openai.scriptResets([behavior], for: account)
            _ = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
            XCTAssertEqual(f.openai.fetchCount, reads, "\(behavior)")
        }
    }

    func testFailuresMapOntoProviderNeutralResults() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        let cases: [(UsageError, ResetResult)] = [
            (.httpStatus(503), .providerError(status: 503)),
            (.forbidden(reason: "Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig denied"), .forbidden(reason: "[redacted] denied")),
            (.transport(URLError(.timedOut)), .unreachable),
            (.tooLarge, .unexpected),
            (.invalidResponse("x"), .unexpected),
            (.rateLimited(retryAfter: nil), .rateLimited(until: nil)),
        ]
        for (error, expected) in cases {
            f.openai.scriptResets([.fail(error)], for: account)
            let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())
            XCTAssertEqual(result, expected, "\(error)")
        }
    }

    func testAProviderWithoutResetsIsUnsupported() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        let scheduler = PollScheduler(
            store: f.store,
            providers: [.openai: ReadOnlyProvider()],
            resolver: PassthroughCredentialResolver(),
            cache: f.cache,
            settings: PollSettings(),
            clock: f.clock
        )
        let result = await scheduler.useReset(accountID: account.id, attemptID: UUID())
        XCTAssertEqual(result, .unsupported)
    }

    func testUnderBackoffTheResetSendsNothing() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script([.succeed(usedPercent: 50), .fail(.rateLimited(retryAfter: 1_800))], for: account)
        await f.scheduler.start()
        await f.waitForCycles(1)
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        await f.scheduler.stop()
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the second read armed a provider-wide horizon")
        let before = try await f.requireEntry(account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(result, .rateLimited(until: f.clock.now().addingTimeInterval(1_800)))
        XCTAssertEqual(f.anthropic.resetCount, 0, "no reset inside the horizon")
        XCTAssertEqual(f.anthropic.fetchCount, 2, "and no read")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after, before, "the row keeps its last good reading with its age")
    }

    func testAnAccountRemovedDuringTheResetGetsNoCacheEntry() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.openai)
        f.openai.scriptResets([.waitThenAnswer(.reset)], for: account)

        let running = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await waitUntil("reset sent") { f.openai.resetCount == 1 }
        try await f.store.remove(id: account.id)
        f.openai.releaseResets()
        let result = await running.value

        XCTAssertEqual(result, .outcome(.reset))
        let entry = await f.entry(account)
        XCTAssertNil(entry, "a removed row never comes back")
        XCTAssertEqual(f.openai.fetchCount, 0, "no read for an account that is gone")
    }

    // MARK: Rotation stays offline

    func testOneHundredRotationTicksDuringAResetIssueNoRequests() async throws {
        let f = makeFixture()
        let resetting = try await f.addAccount(.openai)
        try await f.addAccount(.anthropic)
        f.openai.setResetCredits(1)
        await pollOnceThenStop(f)
        f.openai.scriptResets([.waitThenAnswer(.nothingToReset)], for: resetting)
        let running = Task { await f.scheduler.useReset(accountID: resetting.id, attemptID: UUID()) }
        await waitUntil("reset sent") { f.openai.resetCount == 1 }
        let fetchesBefore = f.totalFetches

        let accounts = AccountOrder.grouped(await f.store.accounts())
        let snapshot = await f.cache.snapshot()
        let now = f.clock.now()
        await MainActor.run {
            let rotation = RotationController(accounts: accounts, statuses: snapshot)
            for _ in 0..<100 {
                rotation.tick()
                _ = rotation.current.map {
                    Formatting.barLabel(account: $0, index: rotation.currentNumber ?? 0, cached: rotation.statuses[$0.id], now: now)
                }
            }
        }
        await f.clock.settle()

        XCTAssertEqual(f.totalFetches, fetchesBefore, "rotation reads the cache only")
        XCTAssertEqual(totalResets(f), 1, "and never resends the reset")
        f.openai.releaseResets()
        _ = await running.value
    }

    // MARK: Reset kinds

    private static let twoKinds = [
        ResetKind(key: .full, label: "Full reset", count: 2),
        ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1),
    ]

    func testPassesChoiceThroughUntouched() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setResetKinds(Self.twoKinds)
        await pollOnceThenStop(f)
        f.anthropic.scriptResets([.answer(.nothingToReset)], for: account)

        _ = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)
        _ = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .full)
        _ = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: nil)
        _ = await f.scheduler.useReset(accountID: account.id, attemptID: UUID())

        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.modelRefill, .full, nil, nil])
    }

    func testPassesChoiceThroughOnTheResendAfterARefresh() async throws {
        let f = makeFixture(refreshingTokens: true)
        let account = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.fail(.needsLogin), .answer(.nothingToReset)], for: account)
        let attemptID = UUID()

        _ = await f.scheduler.useReset(accountID: account.id, attemptID: attemptID, choice: .modelRefill)

        XCTAssertEqual(f.anthropic.resetCalls.map(\.attemptID), [attemptID, attemptID])
        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.modelRefill, .modelRefill], "the resend keeps the kind")
    }

    /// A poll that lands between the click and the confirm, with a changed
    /// kinds list that still holds the chosen kind, never redirects it.
    func testPollDuringConfirmKeepsKind() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setResetKinds(Self.twoKinds)
        await pollOnceThenStop(f)
        f.anthropic.setResetKinds([
            ResetKind(key: .weekly, label: "7-day reset", count: 4),
            ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1),
        ])
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.resetKinds?.map(\.key), [.weekly, .modelRefill])
        f.anthropic.scriptResets([.answer(.reset)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)

        XCTAssertEqual(result, .outcome(.reset))
        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.modelRefill])
    }

    func testTwoKindsAtOnceSendOneRequest() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.waitThenAnswer(.reset)], for: account)

        let first = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .full) }
        await waitUntil("first kind sent") { f.anthropic.resetCount == 1 }
        let second = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)

        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.full], "the second kind sent nothing")
        f.anthropic.releaseResets()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .outcome(.reset))
    }

    func testNeedsFreshReadingReadsOnceWithoutTheSettleDelay() async throws {
        let f = PollingFixture(postResetReadDelay: PollScheduler.postResetReadDelay)
        fixtures.append(f)
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setResetKinds(Self.twoKinds)
        f.anthropic.scriptResets([.answer(.needsFreshReading)], for: account)

        let reset = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .full) }
        await waitUntil("the read, with no clock advanced: nothing was spent, so nothing settles") {
            f.anthropic.fetchCount == 1
        }
        // Only frees a regressed scheduler sleeping on the settle delay.
        await f.clock.advance(by: PollScheduler.postResetReadDelay)
        let result = await reset.value

        XCTAssertEqual(result, .outcome(.needsFreshReading))
        XCTAssertEqual(f.anthropic.fetchCount, 1, "exactly one read")
        let entry = try await f.requireEntry(account)
        XCTAssertEqual(entry.status.resetKinds?.map(\.key), [.full, .modelRefill], "the row then lists its kinds")
    }

    /// A click on a row with no reading this launch, while a poll is
    /// reading that account: the poll's read started before the click, and
    /// nothing was spent, so its reading is the one the click waits for.
    func testClickDuringThePollsFirstReadSendsNoSecondRead() async throws {
        let kinds = ClaudeKindsFixture()
        let account = try await kinds.fixture.addAccount(.anthropic, email: "fixture-unread")
        try kinds.enqueueReading()
        kinds.enqueueProfile()
        kinds.posts.holdReads()
        await kinds.scheduler.start()
        await waitUntil("the poll's read was sent and is held") { kinds.usageReads == 1 }

        let reset = Task { await kinds.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .full) }
        await waitUntil("the click reached the scheduler") { await kinds.scheduler.isResetInFlight(account.id) }
        kinds.posts.releaseReads()
        let result = await reset.value

        XCTAssertEqual(result, .outcome(.needsFreshReading))
        XCTAssertEqual(kinds.usageReads, 1, "the poll's read served the click")
        XCTAssertTrue(kinds.postRequests.isEmpty, "nothing was spent")
        let entry = try await kinds.fixture.requireEntry(account)
        XCTAssertEqual(entry.status.resetKinds?.map(\.key), [.full, .modelRefill], "the row lists its kinds")
        await kinds.cleanUp()
    }

    /// A Claude row restored from a 0.5.1 status cache shows a count and no
    /// kinds, so a click carries no choice: nothing is spent, the account is
    /// read once, and a kind picked from that reading is the one spent.
    func testRowFromA051CacheSpendsNothingOnAClickThenSpendsThePickedKind() async throws {
        let kinds = ClaudeKindsFixture()
        let account = try await kinds.fixture.addAccount(.anthropic, email: "fixture-claude")
        let cached = String(decoding: try TestFixtures.data("status-cache-0.5.1"), as: UTF8.self)
            .replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: account.id.uuidString)
        let restored = try StatusCachePersistence.decode(Data(cached.utf8)).filter { $0.key == account.id }
        await kinds.fixture.cache.seed(from: restored)
        let seeded = try await kinds.fixture.requireEntry(account)
        XCTAssertEqual(seeded.status.resetCreditsAvailable, 3, "the 0.5.1 count")
        XCTAssertNil(seeded.status.resetKinds, "and no kinds")

        try kinds.enqueueReading()
        kinds.enqueueProfile()
        let click = await kinds.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: nil)

        XCTAssertEqual(click, .outcome(.needsFreshReading))
        XCTAssertTrue(kinds.postRequests.isEmpty, "the click spent nothing")
        XCTAssertEqual(kinds.usageReads, 1, "the account was read once")
        let read = try await kinds.fixture.requireEntry(account)
        XCTAssertEqual(read.status.resetKinds?.map(\.key), [.full, .modelRefill], "the row lists its kinds")

        kinds.enqueueResetAnswer()
        try kinds.enqueueReading()
        let pick = await kinds.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)

        XCTAssertEqual(pick, .outcome(.reset))
        XCTAssertEqual(try kinds.grantIDs(), [ClaudeKindsFixture.refillGrant], "the picked kind's grant, once")
        await kinds.cleanUp()
    }

    func testBlockedKindSendsNothingMoreAndReadsNothing() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.answer(.blocked(.usableOnlyAtLimit))], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)

        XCTAssertEqual(result, .outcome(.blocked(.usableOnlyAtLimit)))
        XCTAssertEqual(f.anthropic.fetchCount, 0)
    }

    /// The scheduler side of a choice the adapter cannot resolve: the
    /// adapter answers not-available and the account is read once.
    func testUnresolvableChoiceEndsNotAvailableAndReadsOnce() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.scriptResets([.answer(.notAvailable)], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .session)

        XCTAssertEqual(result, .outcome(.notAvailable))
        XCTAssertEqual(f.anthropic.resetCalls.map(\.choice), [.session], "no other kind substituted")
        XCTAssertEqual(f.anthropic.fetchCount, 1)
    }

    func testKindSpendRateLimitedLeavesThePollBackoffAlone() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.setResetKinds(Self.twoKinds)
        await pollOnceThenStop(f)
        let before = try await f.requireEntry(account)
        f.anthropic.scriptResets([.fail(.rateLimited(retryAfter: 600))], for: account)

        let result = await f.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)

        XCTAssertEqual(result, .rateLimited(until: f.clock.now().addingTimeInterval(600)))
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after, before, "the row's reading, kinds and state are untouched")
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the next poll is not skipped: no horizon was armed")
    }

    func testPollCyclesRefreshNowAndWakeNeverSendAResetWithKinds() async throws {
        let f = makeFixture()
        try await f.addAccount(.anthropic)
        try await f.addAccount(.openai)
        f.anthropic.setResetKinds(Self.twoKinds)
        f.openai.setResetCredits(2)

        await f.scheduler.start()
        await f.waitForCycles(1)
        for cycle in 2...4 {
            await f.clock.advance(by: 300)
            await f.waitForCycles(cycle)
        }
        await f.scheduler.refreshNow()
        await f.waitForCycles(5)
        await f.scheduler.handleWillSleep()
        await f.scheduler.handleDidWake()
        await f.waitForCycles(6)

        XCTAssertEqual(f.totalFetches, 12)
        XCTAssertEqual(totalResets(f), 0, "no cycle, refresh or wake spends any kind")
    }

    func testUnsupportedProviderDefaultAnswersUnsupportedForAnyChoice() async throws {
        let account = Account(provider: .openai, email: "fixture-unsupported", sortIndex: 0)
        let choices: [ResetKind.Key?] = [nil] + ResetKind.Key.allCases.map { $0 }
        for choice in choices {
            do {
                _ = try await ReadOnlyProvider().useReset(
                    account: account,
                    credential: AccountCredential(accessToken: "t"),
                    attemptID: UUID(),
                    choice: choice
                )
                XCTFail("\(String(describing: choice)) should be unsupported")
            } catch {
                XCTAssertTrue(error is ResetUnsupportedError, "\(error)")
            }
        }
    }

    // MARK: Reset kinds over the Claude adapter

    private func kindsFixture() -> ClaudeKindsFixture {
        let kinds = ClaudeKindsFixture()
        addTeardownBlock { await kinds.cleanUp() }
        return kinds
    }

    /// One Claude account read once from the kinds fixture into a started
    /// model, with polling stopped afterwards.
    @MainActor
    private func kindsModel(accounts: Int = 1) async throws -> (ClaudeKindsFixture, ModelHarness, [Account]) {
        let kinds = ClaudeKindsFixture()
        let h = ModelHarness(fixture: kinds.fixture, scheduler: kinds.scheduler)
        addTeardownBlock { await h.cleanUp() }
        var added: [Account] = []
        for number in 0..<accounts {
            added.append(try await kinds.fixture.addAccount(.anthropic, email: "fixture-kinds-\(number)"))
            // Reads within one provider run one after another, so each
            // account takes its reading and then its profile.
            try kinds.enqueueReading()
            kinds.enqueueProfile()
        }
        await h.start()
        await h.stopPolling()
        return (kinds, h, added)
    }

    /// The kinds fixture with the model refill's count set to `left`.
    private static func kindsBody(refillLeft left: Int) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try ClaudeKindsFixture.kindsBody()) as? [String: Any])
        var block = try XCTUnwrap(root[AnthropicResetParser.blockKey] as? [String: Any])
        var grants = try XCTUnwrap(block["grants"] as? [[String: Any]])
        let refill = try XCTUnwrap(grants.firstIndex { $0["id"] as? String == ClaudeKindsFixture.refillGrant })
        grants[refill]["resets_left"] = left
        grants[refill]["resets_total"] = left
        block["grants"] = grants
        root[AnthropicResetParser.blockKey] = block
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Cycles from the timer, a Refresh and a wake, then rotation ticks, over
    /// a Claude account whose reading lists kinds: reads only, no reset POST.
    func testPollCycleWithKindsSendsNoReset() async throws {
        let k = kindsFixture()
        let account = try await k.fixture.addAccount(.anthropic, email: "fixture-kinds")
        try k.enqueueReading()
        k.enqueueProfile()
        for _ in 0..<4 { try k.enqueueReading() }

        await k.scheduler.start()
        await k.fixture.waitForCycles(1, on: k.scheduler)
        let entry = try await k.fixture.requireEntry(account)
        XCTAssertEqual(entry.status.resetKinds?.count, 2, "the reading lists a full reset and a model refill")
        for cycle in 2...3 {
            await k.clock.advance(by: 300)
            await k.fixture.waitForCycles(cycle, on: k.scheduler)
        }
        await k.scheduler.refreshNow()
        await k.fixture.waitForCycles(4, on: k.scheduler)
        await k.scheduler.handleWillSleep()
        await k.scheduler.handleDidWake()
        await k.fixture.waitForCycles(5, on: k.scheduler)
        await k.scheduler.stop()

        let requestsBefore = k.http.requests.count
        let accounts = AccountOrder.grouped(await k.fixture.store.accounts())
        let snapshot = await k.fixture.cache.snapshot()
        let now = k.clock.now()
        await MainActor.run {
            let rotation = RotationController(accounts: accounts, statuses: snapshot)
            for _ in 0..<100 {
                rotation.tick()
                _ = rotation.current.map {
                    Formatting.barLabel(account: $0, index: rotation.currentNumber ?? 0, cached: rotation.statuses[$0.id], now: now)
                }
            }
        }
        await k.clock.settle()

        XCTAssertEqual(k.usageReads, 5, "one read per cycle")
        XCTAssertEqual(k.http.requests.count, requestsBefore, "rotation reads the cache only")
        XCTAssertEqual(k.postRequests.count, 0, "no cycle, Refresh, wake or tick spends any kind")
    }

    /// The counts shown after a kind is spent are the follow-up read's,
    /// whether it reports them unchanged or changed: nothing is subtracted
    /// locally from a kind or from the total.
    func testCountsFromFollowUpReadAfterAKindIsSpent() async throws {
        let k = kindsFixture()
        let account = try await k.addAccountAndReadOnce()
        let before = try await k.fixture.requireEntry(account)
        let kindsBefore = try XCTUnwrap(before.status.resetKinds)
        let refillBefore = try XCTUnwrap(kindsBefore.first { $0.key == .modelRefill }?.count)
        let totalBefore = before.status.resetCreditsAvailable

        k.enqueueResetAnswer()
        try k.enqueueReading()
        let unchanged = await k.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)
        XCTAssertEqual(unchanged, .outcome(.reset))
        let afterUnchanged = try await k.fixture.requireEntry(account)
        XCTAssertEqual(afterUnchanged.status.resetKinds, kindsBefore, "the read reported the same counts, so they stand")
        XCTAssertEqual(afterUnchanged.status.resetCreditsAvailable, totalBefore, "and so does the total")

        k.enqueueResetAnswer()
        k.http.enqueue(status: 200, body: try Self.kindsBody(refillLeft: refillBefore + 3))
        let changed = await k.scheduler.useReset(accountID: account.id, attemptID: UUID(), choice: .modelRefill)
        XCTAssertEqual(changed, .outcome(.reset))
        let afterChanged = try await k.fixture.requireEntry(account)
        XCTAssertEqual(afterChanged.status.resetKinds?.first { $0.key == .modelRefill }?.count, refillBefore + 3)
        XCTAssertEqual(afterChanged.status.resetKinds?.first { $0.key == .full }?.count, kindsBefore.first { $0.key == .full }?.count)
        XCTAssertEqual(afterChanged.status.resetCreditsAvailable, totalBefore.map { $0 + 3 }, "the total is the read's")
        XCTAssertEqual(try k.grantIDs(), [ClaudeKindsFixture.refillGrant, ClaudeKindsFixture.refillGrant])
        XCTAssertEqual(k.usageReads, 3, "the first reading and one read after each spend")
    }

    /// Removing the row while its kind spend is out: the answer (one that
    /// would otherwise leave a retry open) lands nowhere. No attempt, kind,
    /// gate, cache entry, message or read is left behind.
    @MainActor
    func testRemoveOrRenameDuringKindSpendForgetsARemovedRow() async throws {
        let (k, h, added) = try await kindsModel()
        let a = added[0]
        k.http.enqueue(status: 503)
        k.posts.hold()

        h.model.useReset(a, choice: .modelRefill)
        let running = try XCTUnwrap(h.model.resetTasks[a.id])
        await waitUntil("the spend was sent") { k.postRequests.count == 1 }
        h.model.remove(a)
        await h.waitForModel("the row is gone") { $0.accounts.isEmpty }
        k.posts.release()
        await running.value

        XCTAssertNil(h.model.resetNotices[a.id], "no message for a row that is gone")
        XCTAssertNil(h.model.resetGates[a.id], "no retry offered")
        XCTAssertFalse(h.model.resetsInFlight.contains(a.id))
        let state = await k.scheduler.resetAttemptState(for: a.id)
        XCTAssertNil(state, "the scheduler keeps no attempt or kind for it")
        let entry = await k.fixture.entry(a)
        XCTAssertNil(entry, "no cache entry comes back")
        XCTAssertNil(h.model.statuses[a.id])
        XCTAssertEqual(k.usageReads, 1, "no read for an account that is gone")
        XCTAssertEqual(try k.grantIDs(), [ClaudeKindsFixture.refillGrant])
    }

    /// Renaming and moving the row while its kind spend is out lands the
    /// result, the message and the fresh reading on the same account.
    @MainActor
    func testRemoveOrRenameDuringKindSpendLandsOnTheSameAccount() async throws {
        let (k, h, added) = try await kindsModel(accounts: 2)
        let (a, b) = (added[0], added[1])
        let otherBefore = try await k.fixture.requireEntry(b)
        k.enqueueResetAnswer()
        k.http.enqueue(status: 200, body: try Self.kindsBody(refillLeft: 9))
        k.posts.hold()

        h.model.useReset(a, choice: .modelRefill)
        let running = try XCTUnwrap(h.model.resetTasks[a.id])
        await waitUntil("the spend was sent") { k.postRequests.count == 1 }
        h.model.rename(a, to: "Work")
        h.model.moveDown(a)
        await h.waitForModel("rename and move landed") { model in
            model.accounts.map(\.id) == [b.id, a.id] && model.accounts.last?.nickname == "Work"
        }
        k.posts.release()
        await running.value

        XCTAssertEqual(h.model.resetNotices[a.id]?.kind, .success)
        XCTAssertNil(h.model.resetNotices[b.id], "the other row gets nothing")
        let entry = try await k.fixture.requireEntry(a)
        XCTAssertEqual(entry.status.accountID, a.id)
        XCTAssertEqual(entry.status.resetKinds?.first { $0.key == .modelRefill }?.count, 9, "the fresh reading is on the same id")
        let otherAfter = try await k.fixture.requireEntry(b)
        XCTAssertEqual(otherAfter, otherBefore)
        XCTAssertEqual(k.usageReads, 3, "two first readings and one read after the spend")
    }

    /// A kind spend that outlives its send budget is reported as
    /// couldn't-reach and stays open for a retry, which carries the same
    /// request id to the same grant.
    @MainActor
    func testTimedOutKindSpendKeepsItsAttemptAndChoiceForTheRetry() async throws {
        let (k, h, added) = try await kindsModel()
        let a = added[0]
        let label = h.model.statuses[a.id]?.status.resetKinds?.first { $0.key == .modelRefill }?.label
        let budgets = k.clock.parkedCount(interval: PollScheduler.resetTimeout)
        k.enqueueResetAnswer()
        k.posts.hold()

        h.model.useReset(a, choice: .modelRefill)
        let first = try XCTUnwrap(h.model.resetTasks[a.id])
        await waitUntil("the spend was sent") { k.postRequests.count == 1 }
        _ = await k.clock.parkedSleep(interval: PollScheduler.resetTimeout, number: budgets + 1)
        await k.clock.advance(by: PollScheduler.resetTimeout)
        await first.value
        k.posts.release()

        let expected = ResetMessages.notice(for: .unreachable, providerName: Provider.anthropic.displayName, now: Date(), kindLabel: label)
        XCTAssertEqual(h.model.resetNotices[a.id]?.text, expected?.text, "couldn't reach")
        XCTAssertEqual(h.model.resetGates[a.id], .retryOnly(kind: .modelRefill, label: label), "the retry is offered for the same kind")
        let state = await k.scheduler.resetAttemptState(for: a.id)
        guard case .retryable(_, let choice, _) = state else {
            return XCTFail("the attempt is not open for a retry: \(String(describing: state))")
        }
        XCTAssertEqual(choice, .modelRefill)
        XCTAssertEqual(k.usageReads, 1, "an unanswered send reads nothing")

        k.enqueueResetAnswer()
        try k.enqueueReading()
        h.model.useReset(a, choice: .modelRefill, retrying: true)
        try await XCTUnwrap(h.model.resetTasks[a.id]).value

        XCTAssertEqual(h.model.resetNotices[a.id]?.kind, .success)
        XCTAssertEqual(try k.grantIDs(), [ClaudeKindsFixture.refillGrant, ClaudeKindsFixture.refillGrant])
        let requestIDs = try k.requestIDs()
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertNotNil(requestIDs.first ?? nil)
        XCTAssertEqual(requestIDs.first, requestIDs.last, "the retry is the same attempt")
    }
}

/// A provider that implements no reset, so it gets the protocol's default.
private struct ReadOnlyProvider: UsageProvider {
    let provider: Provider = .openai

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        AccountStatus(accountID: account.id, provider: provider, email: account.email, windows: [], fetchedAt: Date(), state: .ok)
    }

    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        credential
    }
}

/// `TokenRefresher.refreshedCredential`: serialized with ordinary
/// resolution, and a no-op when someone already rotated the pair.
final class ForcedRefreshTests: XCTestCase {
    func testForcedRefreshRotatesOnceAndSkipsWhenAlreadyRotated() async throws {
        let f = PollingFixture()
        defer { Task { await f.cleanUp() } }
        let account = try await f.addAccount(.openai)
        let refresher = TokenRefresher(now: { f.clock.now() })
        let stored = try await f.store.credential(for: account.id)
        let rejected = try XCTUnwrap(stored)

        _ = try await refresher.refreshedCredential(replacing: rejected, for: account, from: f.store, using: f.openai)
        XCTAssertEqual(f.openai.refreshCount, 1)

        let rotated = AccountCredential(accessToken: "rotated", refreshToken: "refresh-2", expiresAt: nil)
        try await f.store.updateCredential(rotated, for: account.id)
        let result = try await refresher.refreshedCredential(replacing: rejected, for: account, from: f.store, using: f.openai)
        XCTAssertEqual(result.accessToken, "rotated", "another caller already rotated it")
        XCTAssertEqual(f.openai.refreshCount, 1, "no second refresh")
    }

    func testPassthroughCannotRefresh() async throws {
        let f = PollingFixture()
        defer { Task { await f.cleanUp() } }
        let account = try await f.addAccount(.openai)
        let maybeStored = try await f.store.credential(for: account.id)
        let stored = try XCTUnwrap(maybeStored)
        do {
            _ = try await PassthroughCredentialResolver().refreshedCredential(replacing: stored, for: account, from: f.store, using: f.openai)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
            // expected
        }
        XCTAssertEqual(f.openai.refreshCount, 0)
    }
}
