import Foundation
import XCTest
@testable import Throttle

/// Checks an independent verifier left unproven: a 5xx on the reset re-reads
/// the account, the follow-up read skips when a backoff was armed while the
/// reset ran, no reset identifier ever reaches disk, and a row that needed a
/// sign-in gets its Use reset button back once a poll succeeds.
@MainActor
final class ResetVerificationTests: XCTestCase {
    private var harnesses: [ModelHarness] = []
    private var fixtures: [PollingFixture] = []

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.cleanUp()
        }
        for fixture in fixtures {
            await fixture.cleanUp()
        }
        harnesses = []
        fixtures = []
    }

    private func makeFixture() -> PollingFixture {
        let fixture = PollingFixture()
        fixtures.append(fixture)
        return fixture
    }

    private func pollOnceThenStop(_ f: PollingFixture) async {
        await f.pollOnceThenStop()
    }

    // MARK: ISC-241: a 5xx re-reads that account

    /// A gateway can answer 5xx after the provider spent the reset, so the
    /// row's count may be out of date: the account is read once, the message
    /// never says nothing changed, and the next click reuses the attempt.
    func testA5xxReadsTheAccountOnceAndSaysTryAgain() async throws {
        let f = makeFixture()
        let target = try await f.addAccount(.openai)
        let sibling = try await f.addAccount(.openai)
        f.openai.setResetCredits(2)
        await pollOnceThenStop(f)
        let siblingBefore = try await f.requireEntry(sibling)
        f.openai.setResetCredits(1)
        f.openai.scriptResets([.fail(.httpStatus(502))], for: target)

        let result = await f.scheduler.useReset(accountID: target.id, attemptID: UUID())

        XCTAssertEqual(result, .providerError(status: 502))
        XCTAssertTrue(result.wantsUsageRead)
        XCTAssertEqual(f.openai.fetchCount(for: target), 2, "one read after the 5xx")
        XCTAssertEqual(f.openai.fetchCount(for: sibling), 1, "no other account is read")
        let entry = try await f.requireEntry(target)
        XCTAssertEqual(entry.status.resetCreditsAvailable, 1, "the row shows the provider's fresh count")
        let siblingAfter = try await f.requireEntry(sibling)
        XCTAssertEqual(siblingAfter, siblingBefore)
        let text = ResetMessages.notice(for: result, providerName: "Codex", now: f.clock.now())?.text
        XCTAssertEqual(text, "Codex had a problem (HTTP 502). Try again — a retry never spends a second reset.")
        XCTAssertFalse(text?.contains("Nothing was changed") ?? true)

        // A 4xx was refused before it was processed: no read, old wording.
        f.openai.scriptResets([.fail(.httpStatus(409))], for: target)
        let refused = await f.scheduler.useReset(accountID: target.id, attemptID: UUID())
        XCTAssertEqual(refused, .providerError(status: 409))
        XCTAssertEqual(f.openai.fetchCount(for: target), 2, "no read after a 4xx")
        XCTAssertEqual(ResetMessages.notice(for: refused, providerName: "Codex", now: f.clock.now())?.text,
                       "Codex couldn't use the reset (HTTP 409). Nothing was changed.")
    }

    // MARK: ISC-312: a backoff armed during the reset skips the read

    /// The reset is sent (no horizon when it starts), and while it waits for
    /// its answer a poll of the same account is rate limited. The reset still
    /// lands as used, and the read after it is skipped because a horizon is
    /// now armed: the row keeps its last good numbers with their age. This is
    /// the skip inside `readUsageAfterReset`, not the refusal before sending.
    func testABackoffArmedDuringTheResetSkipsTheReadAfterIt() async throws {
        let f = makeFixture()
        let account = try await f.addAccount(.anthropic)
        f.anthropic.script([.succeed(usedPercent: 70), .fail(.rateLimited(retryAfter: 1_800)), .succeed(usedPercent: 0)], for: account)
        await pollOnceThenStop(f)
        let before = try await f.requireEntry(account)
        f.anthropic.scriptResets([.waitThenAnswer(.reset)], for: account)

        let running = Task { await f.scheduler.useReset(accountID: account.id, attemptID: UUID()) }
        await f.anthropic.waitForResetCalls(1)
        await f.scheduler.refreshNow()
        await f.waitForCycles(2)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "the poll during the reset was rate limited")
        let armedAt = f.clock.now()
        f.anthropic.releaseResets()
        let result = await running.value

        XCTAssertEqual(result, .outcome(.reset), "the reset was sent and used")
        XCTAssertEqual(f.anthropic.resetCount, 1)
        XCTAssertEqual(f.anthropic.fetchCount, 2, "no read after the reset inside the horizon")
        let after = try await f.requireEntry(account)
        XCTAssertEqual(after.status.state, .rateLimited(until: armedAt.addingTimeInterval(1_800)))
        XCTAssertEqual(after.lastGoodWindows, before.lastGoodWindows, "the last good reading is kept")
        XCTAssertEqual(after.status.fetchedAt, before.status.fetchedAt, "with its own age")
    }

    // MARK: ISC-279, ISC-320: no reset identifier reaches disk

    /// A full reset through the model, with a provider that holds a grant id
    /// and an organization uuid and sends both with the attempt id, as the
    /// Claude adapter does. Afterwards none of the three appears in
    /// `accounts.json`, the status cache, the rate-limit file, the
    /// diagnostics log, or the app's defaults domain.
    func testAResetWritesNoAttemptGrantOrOrganizationIdToDisk() async throws {
        let fixture = PollingFixture()
        let probe = IdentifierHoldingProvider(inner: fixture.anthropic)
        let paths = AppPaths(applicationSupportDirectory: fixture.directory)
        let scheduler = PollScheduler(
            store: fixture.store,
            providers: [.anthropic: probe, .openai: fixture.openai],
            resolver: PassthroughCredentialResolver(),
            cache: fixture.cache,
            settings: fixture.settings,
            clock: fixture.clock,
            backoffPersistence: BackoffPersistence(paths: paths),
            postResetReadDelay: fixture.postResetReadDelay
        )
        let harness = ModelHarness(fixture: fixture, scheduler: scheduler)
        harnesses.append(harness)
        let account = try await fixture.addAccount(.anthropic, email: "disk@example.com")
        fixture.anthropic.setResetCredits(2)
        await harness.start()
        await harness.stopPolling()
        fixture.anthropic.setResetCredits(1)
        fixture.anthropic.scriptResets([.answer(.reset)], for: account)

        let model = harness.model
        model.useReset(account)
        try await XCTUnwrap(model.resetTasks[account.id]).value
        await harness.waitForStatus("fresh count published") { $0[account.id]?.status.resetCreditsAvailable == 1 }
        await harness.persistence.flush()

        XCTAssertEqual(model.resetNotices[account.id]?.text, ResetMessages.success)
        let sent = try XCTUnwrap(probe.sentBodies.first, "the reset went out")
        let attemptID = try XCTUnwrap(fixture.anthropic.resetCalls.first?.attemptID)
        let needles = [
            attemptID.uuidString, attemptID.uuidString.lowercased(),
            probe.grantID,
            probe.orgUUID, probe.orgUUID.uppercased(),
        ]
        for needle in needles {
            XCTAssertTrue(sent.contains(needle) || sent.contains(needle.lowercased()), "the provider held \(needle)")
        }

        // Every file the app wrote under its support directory.
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.path)
            .map { fixture.directory.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let names = Set(files.map(\.lastPathComponent))
        XCTAssertTrue(names.contains(paths.accountsFile.lastPathComponent), "accounts.json was written: \(names)")
        XCTAssertTrue(names.contains(paths.statusCacheFile.lastPathComponent), "the status cache was written: \(names)")
        var haystacks: [(String, String)] = try files.map { ($0.lastPathComponent, String(decoding: try Data(contentsOf: $0), as: UTF8.self)) }

        // The app's defaults domain: this harness's private suite.
        let domain = UserDefaults(suiteName: harness.defaultsSuite)?.persistentDomain(forName: harness.defaultsSuite) ?? [:]
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        haystacks.append(("defaults \(harness.defaultsSuite)", String(decoding: plist, as: UTF8.self)))
        XCTAssertFalse(domain.isEmpty, "the model wrote its settings (the plan label) to the domain")

        let accountsJSON = try XCTUnwrap(haystacks.first { $0.0 == paths.accountsFile.lastPathComponent }?.1)
        XCTAssertTrue(accountsJSON.localizedCaseInsensitiveContains(account.id.uuidString), "the grep reads real content")
        for (name, contents) in haystacks {
            for needle in needles {
                XCTAssertFalse(contents.localizedCaseInsensitiveContains(needle), "\(name) contains \(needle)")
            }
        }
    }

    // MARK: ISC-343: sign-in needed, then a good poll re-enables the button

    /// A row holding resets whose token is rejected: the count stays, the
    /// row dims, and its Use reset button greys with its reason. The next
    /// poll succeeds (the user signed in again) and the same row's button is
    /// enabled, with no other action.
    func testAButtonGreyedBySignInIsEnabledOnceAPollSucceeds() async throws {
        let harness = ModelHarness(fixture: PollingFixture())
        harnesses.append(harness)
        let f = harness.fixture
        let account = try await f.addAccount(.openai, email: "signin@example.com")
        f.openai.setResetCredits(2)
        f.openai.script([.succeed(usedPercent: 40), .fail(.needsLogin), .succeed(usedPercent: 35)], for: account)
        await harness.start()
        await harness.stopPolling()
        let model = harness.model

        model.refresh(account)
        await harness.waitForStatus("sign-in needed") { $0[account.id]?.status.state == .needsLogin }
        let signedOut = try XCTUnwrap(model.statuses[account.id])
        let heldCount = try XCTUnwrap(signedOut.status.resetCreditsAvailable)
        XCTAssertEqual(heldCount, 2, "the count stays on the row")
        XCTAssertTrue(AccountRow.isDimmed(signedOut))
        XCTAssertEqual(ResetCreditsColumn.disabledReason(count: heldCount, dimmed: AccountRow.isDimmed(signedOut)),
                       "Refresh this account first", "greyed while sign-in is needed")

        model.refresh(account)
        await harness.waitForStatus("poll succeeded") { $0[account.id]?.status.state == .ok }
        let signedIn = try XCTUnwrap(model.statuses[account.id])
        let count = try XCTUnwrap(signedIn.status.resetCreditsAvailable)
        XCTAssertEqual(count, 2)
        XCTAssertFalse(AccountRow.isDimmed(signedIn))
        XCTAssertNil(ResetCreditsColumn.disabledReason(count: count, dimmed: AccountRow.isDimmed(signedIn)),
                     "the button is enabled once a poll succeeds")
        XCTAssertEqual(f.openai.resetCount, 0, "nothing was spent along the way")
    }
}

/// Wraps a mock and plays the part of an adapter that learned a grant id and
/// an organization uuid from its reads, and sends both with the attempt id
/// when it spends a reset. Every usage read reports a plan, so the model
/// writes its settings to the defaults domain.
private final class IdentifierHoldingProvider: UsageProvider, @unchecked Sendable {
    let provider: Provider = .anthropic
    let grantID = "grant_probe_7c1e9b2a4d"
    let orgUUID = "5f0c2b7e-9a41-4d3c-8e6f-1b2a3c4d5e6f"
    private let inner: MockUsageProvider
    private let lock = NSLock()
    private var bodies: [String] = []

    init(inner: MockUsageProvider) {
        self.inner = inner
    }

    var sentBodies: [String] { lock.withLock { bodies } }

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        let status = try await inner.fetchStatus(account: account, credential: credential)
        return AccountStatus(
            accountID: status.accountID,
            provider: status.provider,
            email: status.email,
            windows: status.windows,
            fetchedAt: status.fetchedAt,
            state: status.state,
            planLabel: "max",
            resetCreditsAvailable: status.resetCreditsAvailable
        )
    }

    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        try await inner.refresh(credential: credential)
    }

    func useReset(account: Account, credential: AccountCredential, attemptID: UUID) async throws -> ResetOutcome {
        let body = #"{"organization":"\#(orgUUID)","grant_id":"\#(grantID)","request_id":"\#(attemptID.uuidString.lowercased())"}"#
        lock.withLock { bodies.append(body) }
        return try await inner.useReset(account: account, credential: credential, attemptID: attemptID)
    }
}
