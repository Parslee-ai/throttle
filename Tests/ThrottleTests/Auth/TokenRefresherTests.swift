import XCTest
@testable import Throttle

final class TokenRefresherTests: XCTestCase {
    private var directory: URL!
    private var credentials: InMemoryCredentialStore!
    private var store: AccountStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleRefresherTests-\(UUID().uuidString)", isDirectory: true)
        credentials = InMemoryCredentialStore()
        store = AccountStore(credentials: credentials, paths: AppPaths(applicationSupportDirectory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let rotated = AccountCredential(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: Date().addingTimeInterval(3600))

    private func addAccount(provider: Provider = .anthropic, expiresIn: TimeInterval?, accessToken: String = "stale") async throws -> Account {
        let credential = AccountCredential(
            accessToken: accessToken,
            refreshToken: "stale-refresh",
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
        return try await store.add(provider: provider, email: "a@example.com", credential: credential)
    }

    // MARK: Expiry policy

    func testFreshCredentialIsReturnedWithoutRefresh() async throws {
        let account = try await addAccount(expiresIn: 3600)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        let credential = try await TokenRefresher().validCredential(for: account, from: store, using: provider)
        XCTAssertEqual(credential.accessToken, "stale")
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testCredentialWithin60SecondsIsRefreshedAndPersisted() async throws {
        let account = try await addAccount(expiresIn: 30)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        let credential = try await TokenRefresher().validCredential(for: account, from: store, using: provider)
        XCTAssertEqual(credential.accessToken, "rotated")
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertEqual(try credentials.load(for: account.id)?.accessToken, "rotated")
        XCTAssertEqual(try credentials.load(for: account.id)?.refreshToken, "rotated-refresh")
    }

    func testOpenAIExpiryComesFromAccessTokenExpWhenExpiresAtIsNil() async throws {
        let soon = Date().addingTimeInterval(10).timeIntervalSince1970
        let expiring = AuthTestSupport.unsignedJWT(["exp": Int(soon)])
        let account = try await addAccount(provider: .openai, expiresIn: nil, accessToken: expiring)
        let provider = AuthCountingProvider(provider: .openai, refreshResult: .success(rotated))
        let credential = try await TokenRefresher().validCredential(for: account, from: store, using: provider)
        XCTAssertEqual(credential.accessToken, "rotated")
        XCTAssertEqual(provider.refreshCount, 1)

        let later = Date().addingTimeInterval(7200).timeIntervalSince1970
        let fresh = AccountCredential(accessToken: AuthTestSupport.unsignedJWT(["exp": Int(later)]), refreshToken: "r")
        XCTAssertFalse(TokenRefresher.needsRefresh(fresh, now: Date()))
    }

    func testCredentialWithoutAnyExpiryIsUsedAsIs() async throws {
        let account = try await addAccount(expiresIn: nil, accessToken: "opaque")
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        let credential = try await TokenRefresher().validCredential(for: account, from: store, using: provider)
        XCTAssertEqual(credential.accessToken, "opaque")
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testMissingCredentialThrowsNeedsLogin() async throws {
        let account = try await addAccount(expiresIn: 3600)
        try credentials.delete(for: account.id)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        do {
            _ = try await TokenRefresher().validCredential(for: account, from: store, using: provider)
            XCTFail("expected needsLogin")
        } catch UsageError.needsLogin {
            // expected
        }
    }

    // MARK: Serialisation (ISC-63/84)

    func testTenConcurrentCallersProduceExactlyOneRefresh() async throws {
        let account = try await addAccount(expiresIn: 30)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        provider.refreshDelay = .milliseconds(150)
        let refresher = TokenRefresher()
        let store = self.store!

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await refresher.validCredential(for: account, from: store, using: provider).accessToken
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(tokens, Array(repeating: "rotated", count: 10))
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertEqual(try credentials.load(for: account.id)?.accessToken, "rotated")
    }

    func testDifferentAccountsRefreshIndependently() async throws {
        let first = try await addAccount(expiresIn: 30)
        let second = try await store.add(
            provider: .openai, email: "b@example.com",
            credential: AccountCredential(accessToken: "stale-2", refreshToken: "r2", expiresAt: Date().addingTimeInterval(30))
        )
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        provider.refreshDelay = .milliseconds(100)
        let refresher = TokenRefresher()
        let store = self.store!
        async let a = refresher.validCredential(for: first, from: store, using: provider)
        async let b = refresher.validCredential(for: second, from: store, using: provider)
        _ = try await (a, b)
        XCTAssertEqual(provider.refreshCount, 2)
    }

    func testSecondRoundAfterCompletionUsesTheRotatedCredential() async throws {
        let account = try await addAccount(expiresIn: 30)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        let refresher = TokenRefresher()
        _ = try await refresher.validCredential(for: account, from: store, using: provider)
        let again = try await refresher.validCredential(for: account, from: store, using: provider)
        XCTAssertEqual(again.accessToken, "rotated")
        XCTAssertEqual(provider.refreshCount, 1, "the rotated credential is fresh, so no second refresh")
    }

    // MARK: Never cancelled (ISC-64/84)

    func testCancellingTheCallerDoesNotCancelTheRefresh() async throws {
        let account = try await addAccount(expiresIn: 30)
        let provider = AuthCountingProvider(refreshResult: .success(rotated))
        provider.refreshDelay = .milliseconds(300)
        let refresher = TokenRefresher()
        let store = self.store!

        let caller = Task {
            try await refresher.validCredential(for: account, from: store, using: provider)
        }
        // Let the refresh start, then tear the caller down mid-flight.
        let started = await AuthTestSupport.eventually { provider.refreshCount == 1 }
        XCTAssertTrue(started)
        caller.cancel()
        _ = try? await caller.value

        let credentials = self.credentials!
        let persisted = await AuthTestSupport.eventually(timeout: 5) {
            (try? credentials.load(for: account.id))??.accessToken == "rotated"
        }
        XCTAssertTrue(persisted, "the rotated token must reach the store even though the caller was cancelled")
        XCTAssertEqual(provider.refreshCount, 1)
    }

    // MARK: Failure (ISC-65/85)

    func testNeedsLoginFromRefreshPropagatesToEveryCallerAndKeepsTheAccount() async throws {
        let account = try await addAccount(expiresIn: 30)
        let provider = AuthCountingProvider(refreshResult: .failure(UsageError.needsLogin))
        provider.refreshDelay = .milliseconds(100)
        let refresher = TokenRefresher()
        let store = self.store!

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await refresher.validCredential(for: account, from: store, using: provider)
                        return false
                    } catch UsageError.needsLogin {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(failures, 3)
        XCTAssertEqual(provider.refreshCount, 1)
        let accounts = await store.accounts()
        XCTAssertEqual(accounts.map(\.id), [account.id], "a failed refresh never removes the account")
        XCTAssertEqual(try credentials.load(for: account.id)?.accessToken, "stale", "a failed refresh leaves the stored credential alone")
    }
}
