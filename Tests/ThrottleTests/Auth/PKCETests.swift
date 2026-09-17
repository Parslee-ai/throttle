import XCTest
@testable import Throttle

final class PKCETests: XCTestCase {
    private let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    func testVerifierIs64RandomBytesAsBase64URL() {
        let pair = PKCE.generate()
        // 64 bytes → 86 base64 characters without padding.
        XCTAssertEqual(pair.verifier.count, 86)
        XCTAssertTrue(pair.verifier.unicodeScalars.allSatisfy { base64URLCharacters.contains($0) })
        XCTAssertFalse(pair.verifier.contains("="))
        XCTAssertTrue((43...128).contains(pair.verifier.count), "RFC 7636 verifier length")
    }

    func testChallengeIsS256OfVerifier() {
        let pair = PKCE.generate()
        // SHA-256 is 32 bytes → 43 base64url characters.
        XCTAssertEqual(pair.challenge.count, 43)
        XCTAssertEqual(pair.challenge, PKCE.challenge(for: pair.verifier))
        XCTAssertTrue(pair.challenge.unicodeScalars.allSatisfy { base64URLCharacters.contains($0) })
    }

    /// RFC 7636 Appendix B known-answer vector.
    func testS256KnownAnswer() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomStateIs32BytesBase64URL() {
        let state = PKCE.randomState()
        XCTAssertEqual(state.count, 43)
        XCTAssertTrue(state.unicodeScalars.allSatisfy { base64URLCharacters.contains($0) })
    }

    func testEachGenerationIsUnique() {
        let pairs = (0..<50).map { _ in PKCE.generate() }
        XCTAssertEqual(Set(pairs.map(\.verifier)).count, 50)
        XCTAssertEqual(Set((0..<50).map { _ in PKCE.randomState() }).count, 50)
    }
}
