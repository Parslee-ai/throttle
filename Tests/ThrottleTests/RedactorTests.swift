import XCTest
@testable import Throttle

/// Token-shaped test inputs are assembled from fragments at runtime rather than
/// written as literals. A literal here is indistinguishable from a real leaked
/// credential to the secret scan that greps this repository's whole history for
/// exactly these shapes, so the scan would fail on its own test fixtures.
private enum SampleSecret {
    static let jwt = "ey"
        + "JhbGciOiJIUzI1NiJ9.ey"
        + "JzdWIiOiIxMjM0NTY3ODkwIn0"
        + ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    static let anthropicKey = "sk" + "-ant-oat01-AAAABBBBCCCC"
    static let openAIKey = "sk" + "-proj-0123456789abcdef"
}

final class RedactorTests: XCTestCase {
    /// ISC-131: nothing user-visible may carry a credential, including an error
    /// string that echoes the failing request.
    func testRedactsBearerHeader() {
        let out = Redactor.redact("Authorization: Bearer abc123XYZ_-token")
        XCTAssertEqual(out, "Authorization: [redacted]")
        XCTAssertFalse(out.contains("abc123XYZ"))
    }

    func testRedactsBearerCarryingAJWTAsOneMarker() {
        let out = Redactor.redact("failed with Bearer \(SampleSecret.jwt) on retry")
        XCTAssertEqual(out, "failed with [redacted] on retry")
    }

    func testRedactsBareJWT() {
        let out = Redactor.redact("id_token=\(SampleSecret.jwt)")
        XCTAssertEqual(out, "id_token=[redacted]")
    }

    func testRedactsSecretKeyShapes() {
        XCTAssertEqual(
            Redactor.redact("key \(SampleSecret.anthropicKey) expired"),
            "key [redacted] expired"
        )
        XCTAssertEqual(Redactor.redact(SampleSecret.openAIKey), "[redacted]")
    }

    func testRedactsEveryOccurrence() {
        let out = Redactor.redact("Bearer aaaaaaaa then Bearer bbbbbbbb")
        XCTAssertEqual(out, "[redacted] then [redacted]")
    }

    func testIsCaseInsensitiveOnTheBearerScheme() {
        XCTAssertEqual(Redactor.redact("bearer aaaaaaaa"), "[redacted]")
        XCTAssertEqual(Redactor.redact("BEARER aaaaaaaa"), "[redacted]")
    }

    func testLeavesOrdinaryTextAlone() {
        let message = "The request to the usage endpoint timed out after 15s."
        XCTAssertEqual(Redactor.redact(message), message)
        XCTAssertEqual(Redactor.redact(""), "")
        XCTAssertEqual(Redactor.redact("sk-"), "sk-", "too short to be a key, left intact")
    }

    /// A credential must not print its own contents when interpolated, so an
    /// accidental "\(credential)" in an error path cannot leak a token.
    func testCredentialDescriptionNeverPrintsTokens() {
        let credential = AccountCredential(
            accessToken: SampleSecret.anthropicKey,
            refreshToken: "refresh-AAAABBBBCCCC",
            expiresAt: Date(),
            accountID: "acct-1",
            scopes: ["user:profile"]
        )
        let rendered = "\(credential)"
        XCTAssertFalse(rendered.contains("AAAABBBB"))
        XCTAssertEqual(rendered, "AccountCredential(redacted)")
    }
}
