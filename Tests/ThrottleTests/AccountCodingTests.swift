import XCTest
@testable import Throttle

final class AccountCodingTests: XCTestCase {
    /// ISC-42: `Account` is the on-disk, non-secret record. If anyone ever adds a
    /// token-shaped property to it, that secret lands in plain text in
    /// `accounts.json`. This test is the guard.
    func testEncodedAccountHasNoCredentialKeys() throws {
        let account = Account(
            provider: .anthropic,
            email: "someone@example.com",
            sortIndex: 0
        )
        let data = try JSONEncoder().encode(account)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let forbidden = try NSRegularExpression(pattern: "token|secret|refresh", options: [.caseInsensitive])
        for key in object.keys {
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertNil(
                forbidden.firstMatch(in: key, range: range),
                "Account encoded a credential-shaped key: \(key)"
            )
        }
    }

    func testEncodedAccountCarriesExactlyTheNonSecretFields() throws {
        let account = Account(
            provider: .openai,
            email: "someone@example.com",
            sortIndex: 3
        )
        let data = try JSONEncoder().encode(account)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "provider", "email", "sortIndex", "addedAt"])
    }

    func testNicknameIsEncodedOnlyWhenSet() throws {
        let named = Account(provider: .anthropic, email: "someone@example.com", nickname: "Work", sortIndex: 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "provider", "email", "nickname", "sortIndex", "addedAt"])
        XCTAssertEqual(object["nickname"] as? String, "Work")
    }

    /// An `accounts.json` written before renaming existed has no `nickname`
    /// key. It must still load, with the email as the display name.
    func testLegacyRecordWithoutNicknameDecodes() throws {
        let id = UUID()
        let json = """
        {"addedAt": 1780000000, "email": "someone@example.com", "id": "\(id.uuidString)", "provider": "anthropic", "sortIndex": 2}
        """
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.id, id)
        XCTAssertNil(account.nickname)
        XCTAssertEqual(account.displayName, "someone@example.com")
        XCTAssertEqual(account.sortIndex, 2)
    }

    func testDisplayNamePrefersANonEmptyNickname() {
        var account = Account(provider: .openai, email: "someone@example.com", sortIndex: 0)
        XCTAssertEqual(account.displayName, "someone@example.com")
        account.nickname = "Side project"
        XCTAssertEqual(account.displayName, "Side project")
        account.nickname = "   "
        XCTAssertEqual(account.displayName, "someone@example.com")
        account.nickname = ""
        XCTAssertEqual(account.displayName, "someone@example.com")
    }

    func testAccountRoundTrips() throws {
        let account = Account(
            id: UUID(),
            provider: .anthropic,
            email: "someone@example.com",
            sortIndex: 7,
            addedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(account)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), account)
    }
}
