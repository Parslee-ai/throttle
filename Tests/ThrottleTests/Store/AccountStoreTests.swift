import XCTest
@testable import Throttle

final class AccountStoreTests: XCTestCase {
    private var directory: URL!
    private var paths: AppPaths!
    private var credentials: InMemoryCredentialStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleStoreTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupportDirectory: directory)
        credentials = InMemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> AccountStore {
        AccountStore(credentials: credentials, paths: paths)
    }

    private func credential(_ token: String) -> AccountCredential {
        AccountCredential(accessToken: token, refreshToken: "refresh-\(token)", expiresAt: Date(), scopes: ["usage"])
    }

    private func fileMode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw XCTSkip("stat failed: \(errno)")
        }
        return info.st_mode & 0o777
    }

    // MARK: Drag reorder (ISC-92)

    func testMoveToIndexReordersAndPersists() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        let b = try await store.add(provider: .anthropic, email: "b@example.com", credential: credential("b"))
        let c = try await store.add(provider: .openai, email: "c@example.com", credential: credential("c"))

        try await store.move(id: a.id, to: 2)
        var order = await store.accounts().map(\.id)
        XCTAssertEqual(order, [b.id, c.id, a.id])

        try await store.move(id: c.id, to: 0)
        order = await store.accounts().map(\.id)
        XCTAssertEqual(order, [c.id, b.id, a.id])

        let reloaded = try await makeStore().load()
        XCTAssertEqual(reloaded.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(reloaded.map(\.sortIndex), [0, 1, 2])
    }

    // MARK: Loading

    func testLoadWithMissingFileReturnsEmpty() async throws {
        let store = makeStore()
        let accounts = try await store.load()
        XCTAssertEqual(accounts, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.accountsFile.path))
    }

    func testAddThenReloadPreservesOrderEmailsAndIDs() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "First@Example.com", credential: credential("a"))
        let b = try await store.add(provider: .openai, email: "second@example.com", credential: credential("b"))
        let c = try await store.add(provider: .anthropic, email: "third@example.com", credential: credential("c"))

        let reloaded = makeStore()
        let accounts = try await reloaded.load()
        XCTAssertEqual(accounts.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(accounts.map(\.email), ["First@Example.com", "second@example.com", "third@example.com"])
        XCTAssertEqual(accounts.map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(accounts.map(\.provider), [.anthropic, .openai, .anthropic])
    }

    func testAccountsAreSortedBySortIndexThenAddedAt() async throws {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let seeded = [
            Account(provider: .anthropic, email: "z@example.com", sortIndex: 2, addedAt: early),
            Account(provider: .openai, email: "y@example.com", sortIndex: 0, addedAt: late),
            Account(provider: .openai, email: "x@example.com", sortIndex: 0, addedAt: early),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AccountStore.encode(seeded).write(to: paths.accountsFile)

        let store = makeStore()
        let accounts = try await store.load()
        XCTAssertEqual(accounts.map(\.email), ["x@example.com", "y@example.com", "z@example.com"])
    }

    // MARK: Dedupe

    func testAddingSameProviderAndEmailReplacesCredentialAndKeepsID() async throws {
        let store = makeStore()
        let original = try await store.add(provider: .anthropic, email: "Someone@Example.com", credential: credential("old"))
        _ = try await store.add(provider: .openai, email: "other@example.com", credential: credential("other"))
        let replaced = try await store.add(provider: .anthropic, email: "someone@example.com", credential: credential("new"))

        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.sortIndex, original.sortIndex)
        XCTAssertEqual(replaced.email, "someone@example.com", "new casing is adopted")
        let accounts = await store.accounts()
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(try credentials.load(for: original.id)?.accessToken, "new")
    }

    func testSameEmailOnDifferentProviderIsASeparateAccount() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "same@example.com", credential: credential("a"))
        let b = try await store.add(provider: .openai, email: "same@example.com", credential: credential("b"))
        XCTAssertNotEqual(a.id, b.id)
        let count = await store.accounts().count
        XCTAssertEqual(count, 2)
    }

    // MARK: Remove

    func testRemoveClearsBothStores() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        let b = try await store.add(provider: .openai, email: "b@example.com", credential: credential("b"))

        try await store.remove(id: a.id)

        XCTAssertNil(try credentials.load(for: a.id))
        XCTAssertEqual(credentials.storedIDs, [b.id])
        let remaining = try await makeStore().load()
        XCTAssertEqual(remaining.map(\.id), [b.id])
    }

    func testRemoveUnknownIDThrows() async throws {
        let store = makeStore()
        do {
            try await store.remove(id: UUID())
            XCTFail("expected a throw")
        } catch AccountStoreError.unknownAccount {
        }
    }

    // MARK: Reorder

    func testMoveRenumbersAndPersists() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        let b = try await store.add(provider: .openai, email: "b@example.com", credential: credential("b"))
        let c = try await store.add(provider: .anthropic, email: "c@example.com", credential: credential("c"))

        try await store.move(id: c.id, to: 0)
        var ids = await store.accounts().map(\.id)
        XCTAssertEqual(ids, [c.id, a.id, b.id])

        try await store.moveDown(id: c.id)
        try await store.moveUp(id: b.id)
        ids = await store.accounts().map(\.id)
        XCTAssertEqual(ids, [a.id, b.id, c.id])

        try await store.moveUp(id: a.id)
        try await store.moveDown(id: c.id)
        try await store.move(id: b.id, to: 99)
        let reloaded = try await makeStore().load()
        XCTAssertEqual(reloaded.map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(reloaded.map(\.sortIndex), [0, 1, 2])
    }

    func testUpdateEmailPersists() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        try await store.updateEmail(id: a.id, email: "renamed@example.com")
        let reloaded = try await makeStore().load()
        XCTAssertEqual(reloaded.first?.email, "renamed@example.com")
    }

    func testUpdateCredentialReplacesOnlyTheKeychainHalf() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        let before = try Data(contentsOf: paths.accountsFile)
        try await store.updateCredential(credential("rotated"), for: a.id)
        let loaded = try await store.credential(for: a.id)
        XCTAssertEqual(loaded?.accessToken, "rotated")
        XCTAssertEqual(try Data(contentsOf: paths.accountsFile), before)
    }

    // MARK: File hygiene

    func testAccountsFileHasMode0600AndDirectory0700() async throws {
        let store = makeStore()
        _ = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        XCTAssertEqual(try fileMode(paths.accountsFile), 0o600)
        XCTAssertEqual(try fileMode(directory), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.accountsFile.appendingPathExtension("tmp").path))
    }

    func testEncodedJSONHasNoCredentialKeysAndNoLongStrings() async throws {
        let store = makeStore()
        _ = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        _ = try await store.add(provider: .openai, email: "b@example.com", credential: credential("b"))
        let data = try Data(contentsOf: paths.accountsFile)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("refresh-a"))

        let forbidden = try NSRegularExpression(pattern: "token|secret|refresh", options: [.caseInsensitive])
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)
        for object in array {
            for (key, value) in object {
                XCTAssertNil(forbidden.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)), "credential-shaped key: \(key)")
                if let string = value as? String {
                    XCTAssertLessThanOrEqual(string.count, AccountStore.maximumStringLength)
                }
            }
        }
    }

    func testEncoderRefusesStringsOver200Characters() async throws {
        let store = makeStore()
        let longEmail = String(repeating: "x", count: 300) + "@example.com"
        do {
            _ = try await store.add(provider: .anthropic, email: longEmail, credential: credential("a"))
            XCTFail("expected a throw")
        } catch AccountStoreError.stringTooLong(let length, let limit) {
            XCTAssertEqual(length, 312)
            XCTAssertEqual(limit, 200)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.accountsFile.path))

        let seeded = [Account(provider: .openai, email: String(repeating: "y", count: 201), sortIndex: 0)]
        XCTAssertThrowsError(try AccountStore.encode(seeded))
    }

    func testMalformedFileThrowsAndIsLeftInPlace() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: paths.accountsFile)

        let store = makeStore()
        do {
            _ = try await store.load()
            XCTFail("expected a throw")
        } catch {}

        do {
            _ = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
            XCTFail("a mutation must not overwrite a malformed file")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: paths.accountsFile), garbage)
        XCTAssertTrue(credentials.storedIDs.isEmpty)
    }

    // MARK: Missing credentials

    func testMissingCredentialIDsReportsAccountsWithoutKeychainItems() async throws {
        let store = makeStore()
        let a = try await store.add(provider: .anthropic, email: "a@example.com", credential: credential("a"))
        let b = try await store.add(provider: .openai, email: "b@example.com", credential: credential("b"))
        let c = try await store.add(provider: .anthropic, email: "c@example.com", credential: credential("c"))
        try credentials.delete(for: a.id)
        try credentials.delete(for: c.id)

        let reloaded = makeStore()
        _ = try await reloaded.load()
        let missing = await reloaded.missingCredentialIDs()
        XCTAssertEqual(Set(missing), [a.id, c.id])
        let accounts = await reloaded.accounts()
        XCTAssertEqual(accounts.count, 3, "accounts with missing credentials are never dropped")
        _ = b
    }
}
