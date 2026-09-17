import XCTest
@testable import Throttle

/// Talks to the real login Keychain, so it only runs when explicitly asked:
/// `THROTTLE_KEYCHAIN_TESTS=1`. It uses a throwaway service name and never
/// touches items under `ai.parslee.throttle`.
final class KeychainStoreTests: XCTestCase {
    private let service = "ai.parslee.throttle.tests"

    func testSaveLoadDeleteRoundTripAgainstTheLoginKeychain() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THROTTLE_KEYCHAIN_TESTS"] == "1",
            "set THROTTLE_KEYCHAIN_TESTS=1 to run the real Keychain test"
        )
        let store = KeychainStore(service: service)
        let id = UUID()
        defer { try? store.delete(for: id) }

        XCTAssertNil(try store.load(for: id))

        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(
            AccountCredential(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: expiry, accountID: "acct_1", scopes: ["a", "b"]),
            for: id
        )
        let first = try XCTUnwrap(try store.load(for: id))
        XCTAssertEqual(first.accessToken, "access-1")
        XCTAssertEqual(first.refreshToken, "refresh-1")
        XCTAssertEqual(first.expiresAt, expiry)
        XCTAssertEqual(first.accountID, "acct_1")
        XCTAssertEqual(first.scopes, ["a", "b"])
        XCTAssertEqual(try securityLookupStatus(id), 0, "item should be visible to `security`")

        // Upsert path.
        try store.save(AccountCredential(accessToken: "access-2", refreshToken: nil, scopes: []), for: id)
        let second = try XCTUnwrap(try store.load(for: id))
        XCTAssertEqual(second.accessToken, "access-2")
        XCTAssertNil(second.refreshToken)
        XCTAssertNil(second.expiresAt)

        try store.delete(for: id)
        XCTAssertNil(try store.load(for: id))
        XCTAssertNotEqual(try securityLookupStatus(id), 0, "`security find-generic-password` must fail after delete")

        // Idempotent delete.
        XCTAssertNoThrow(try store.delete(for: id))
    }

    /// Exit status of `security find-generic-password -s <service> -a <uuid>`.
    private func securityLookupStatus(_ id: UUID) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", id.uuidString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
