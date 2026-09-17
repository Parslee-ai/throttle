import XCTest
@testable import Throttle

final class JWTClaimsTests: XCTestCase {
    /// ISC-82: the account id and plan come out of the namespaced auth claim.
    func testDecodesOpenAIAuthClaim() throws {
        let token = try OpenAIFixtures.unsignedJWT(payload: [
            "email": "person@example.com",
            "exp": 1_800_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-abc",
                "chatgpt_plan_type": "pro",
                "user_id": "user-xyz",
            ],
        ])

        let claims = try XCTUnwrap(JWTClaims.decode(token))
        XCTAssertEqual(claims.email, "person@example.com")
        XCTAssertEqual(claims.exp, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(claims.chatgptAccountID, "acct-abc")
        XCTAssertEqual(claims.chatgptPlanType, "pro")
    }

    func testMissingClaimsDecodeAsNil() throws {
        let token = try OpenAIFixtures.unsignedJWT(payload: ["sub": "x"])
        let claims = try XCTUnwrap(JWTClaims.decode(token))
        XCTAssertEqual(claims, JWTClaims())
    }

    func testHandlesBase64URLWithoutPadding() throws {
        // A payload whose base64 length is not a multiple of four.
        let token = try OpenAIFixtures.unsignedJWT(payload: ["email": "a@b.co"])
        XCTAssertFalse(token.contains("="), "test premise: the token must be unpadded")
        XCTAssertEqual(JWTClaims.decode(token)?.email, "a@b.co")
    }

    func testRejectsMalformedTokens() {
        XCTAssertNil(JWTClaims.decode(""))
        XCTAssertNil(JWTClaims.decode("not-a-jwt"))
        XCTAssertNil(JWTClaims.decode("a.b"))
        XCTAssertNil(JWTClaims.decode("a.!!!.c"))
        XCTAssertNil(JWTClaims.decode("a.\(OpenAIFixtures.base64URL(Data("[1,2]".utf8))).c"))
    }
}
