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
