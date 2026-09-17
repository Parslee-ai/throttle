import XCTest
@testable import Throttle

/// ISC-61/81: the refresh-token expiry and the OpenID `id_token` are stored
/// with the credential, and a blob written before they existed still loads.
final class CredentialFieldsTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private var full: AccountCredential {
        AccountCredential(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: expiry,
            accountID: "acct_1",
            scopes: ["a"],
            refreshTokenExpiresAt: expiry.addingTimeInterval(86_400),
            idToken: "id-token-1"
        )
    }

    func testInMemoryStoreRoundTripsTheNewFields() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        try store.save(full, for: id)
        let loaded = try XCTUnwrap(try store.load(for: id))
        XCTAssertEqual(loaded.refreshTokenExpiresAt, expiry.addingTimeInterval(86_400))
        XCTAssertEqual(loaded.idToken, "id-token-1")
    }

    func testKeychainBlobRoundTripsTheNewFields() throws {
        let data = try KeychainStore.encodeBlob(full)
        let decoded = try KeychainStore.decodeBlob(data)
        XCTAssertEqual(decoded.accessToken, "access-1")
        XCTAssertEqual(decoded.refreshToken, "refresh-1")
        XCTAssertEqual(decoded.expiresAt, expiry)
        XCTAssertEqual(decoded.accountID, "acct_1")
        XCTAssertEqual(decoded.scopes, ["a"])
        XCTAssertEqual(decoded.refreshTokenExpiresAt, expiry.addingTimeInterval(86_400))
        XCTAssertEqual(decoded.idToken, "id-token-1")
    }

    func testOldKeychainBlobWithoutTheNewKeysStillDecodes() throws {
        let old = """
        {"accessToken":"access-old","refreshToken":"refresh-old","expiresAt":"2027-01-15T08:00:00Z","accountID":"acct_old","scopes":["x","y"]}
        """
        let decoded = try KeychainStore.decodeBlob(Data(old.utf8))
        XCTAssertEqual(decoded.accessToken, "access-old")
        XCTAssertEqual(decoded.refreshToken, "refresh-old")
        XCTAssertEqual(decoded.accountID, "acct_old")
        XCTAssertEqual(decoded.scopes, ["x", "y"])
        XCTAssertNil(decoded.refreshTokenExpiresAt)
        XCTAssertNil(decoded.idToken)
    }

    func testDefaultsAreNil() {
        let minimal = AccountCredential(accessToken: "t")
        XCTAssertNil(minimal.refreshTokenExpiresAt)
        XCTAssertNil(minimal.idToken)
    }
}
