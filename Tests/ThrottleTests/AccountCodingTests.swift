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
