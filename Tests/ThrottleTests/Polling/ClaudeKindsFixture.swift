import Foundation
import XCTest
@testable import Throttle

/// A scheduler driving the real Claude adapter over the scripted HTTP client
/// the adapter tests use, sharing a `PollingFixture`'s store, cache and
/// clock. The clock starts inside the kinds fixture's grant dates, so its
/// full reset (two grants) and its model refill are both spendable.
///
/// The HTTP client answers in order: queue a usage reading and a profile
/// before the first read, and an answer for every request a step sends.
struct ClaudeKindsFixture {
    static let start = Date.iso("2026-07-13T12:00:00Z")
    static let organization = "7e57ab1e-0000-4000-8000-00000000f10e"
    /// The model refill's grant in `anthropic-resets-kinds.json`.
    static let refillGrant = "grant-sentinel-1"
    /// The full reset's grant that ends soonest, the one a full reset spends.
    static let fullGrant = "grant-full-soon"

    let fixture: PollingFixture
    let http: AnthropicMockHTTPClient
    /// Holds each POST, once recorded, until the test opens it.
    let posts: HeldPosts
    let scheduler: PollScheduler

    init(settings: PollSettings = PollSettings(stagger: 0)) {
        self.init(fixture: PollingFixture(settings: settings, clock: TestClock(start: Self.start)))
    }

    /// A Claude scheduler over `fixture`'s store, cache and clock, such as a
    /// relaunch of an earlier fixture.
    init(fixture: PollingFixture) {
        let clock = fixture.clock
        let http = AnthropicMockHTTPClient()
        let posts = HeldPosts(http)
        self.fixture = fixture
        self.http = http
        self.posts = posts
        scheduler = PollScheduler(
            store: fixture.store,
            providers: [.anthropic: AnthropicProvider(client: posts, now: { clock.now() }), .openai: fixture.openai],
            resolver: fixture.resolver,
            cache: fixture.cache,
            settings: fixture.settings,
            clock: clock,
            backoffPersistence: BackoffPersistence(paths: AppPaths(applicationSupportDirectory: fixture.directory)),
            postResetReadDelay: 0
        )
    }

    var clock: TestClock { fixture.clock }

    // MARK: Scripting

    static func kindsBody() throws -> Data {
        try AnthropicFixtures.data("anthropic-resets-kinds")
    }

    /// The kinds fixture with its reset block replaced by `block`.
    static func body(withResetBlock block: String) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try kindsBody()) as? [String: Any])
        root[AnthropicResetParser.blockKey] = try JSONSerialization.jsonObject(with: Data(block.utf8))
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A usage reading of the kinds fixture.
    func enqueueReading() throws {
        http.enqueue(status: 200, body: try Self.kindsBody())
    }

    /// The profile the first read of a launch asks for.
    func enqueueProfile() {
        http.enqueue(status: 200, body: Data(#"{"organization":{"uuid":"\#(Self.organization)","organization_type":"claude_max"}}"#.utf8))
    }

    func enqueueResetAnswer(_ result: String = "reset") {
        http.enqueue(status: 200, body: Data(#"{"result":"\#(result)"}"#.utf8))
    }

    /// Adds the account and runs one poll cycle over the kinds fixture,
    /// then stops the timer, so only explicit calls send anything after.
    func addAccountAndReadOnce(email: String = "fixture-kinds") async throws -> Account {
        let account = try await fixture.addAccount(.anthropic, email: email)
        try enqueueReading()
        enqueueProfile()
        await fixture.runFirstCycle(on: scheduler) { await scheduler.start() }
        await scheduler.stop()
        return account
    }

    // MARK: What was sent

    var postRequests: [URLRequest] { http.requests.filter { $0.httpMethod == "POST" } }

    var usageReads: Int { http.requests.filter { $0.url == AnthropicEndpoints.usage }.count }

    func postBodies() throws -> [[String: Any]] {
        try postRequests.map { post in
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: Any])
        }
    }

    func grantIDs() throws -> [String?] {
        try postBodies().map { $0["grant_id"] as? String }
    }

    func requestIDs() throws -> [String?] {
        try postBodies().map { $0["request_id"] as? String }
    }

    func cleanUp() async {
        posts.release()
        await scheduler.stop()
        await fixture.cleanUp()
    }
}

/// Passes every request to the scripted client, and while `hold()` is in
/// force keeps a POST's answer back until `release()`. The POST is recorded
/// before it waits, so a test can wait for it to be sent.
final class HeldPosts: HTTPClient, @unchecked Sendable {
    private let inner: AnthropicMockHTTPClient
    private let lock = NSLock()
    private var gate: Gate?

    init(_ inner: AnthropicMockHTTPClient) {
        self.inner = inner
    }

    /// Holds every POST from now until `release()`.
    func hold() {
        lock.lock(); defer { lock.unlock() }
        if gate == nil { gate = Gate() }
    }

    func release() {
        lock.lock()
        let held = gate
        gate = nil
        lock.unlock()
        held?.open()
    }

    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse {
        let answer: Result<HTTPResponse, any Error>
        do {
            answer = .success(try await inner.send(request, maxBodyBytes: maxBodyBytes))
        } catch {
            answer = .failure(error)
        }
        if request.httpMethod == "POST", let gate = currentGate() {
            await gate.wait()
        }
        return try answer.get()
    }

    private func currentGate() -> Gate? {
        lock.lock(); defer { lock.unlock() }
        return gate
    }
}
