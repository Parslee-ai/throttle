import Foundation

/// The handful of claims Throttle reads out of an OpenAI JWT.
///
/// Signatures are deliberately not verified. The token was handed to us over
/// TLS by the issuer itself, and the only party that could forge one is the
/// user holding their own Keychain. Nothing here grants access: the claims
/// only label an account and schedule a refresh, and the server re-checks the
/// real signature on every request.
struct JWTClaims: Equatable, Sendable {
    var email: String?
    var exp: Date?
    /// `chatgpt_account_id` inside the `https://api.openai.com/auth` claim.
    var chatgptAccountID: String?
    /// `chatgpt_plan_type` inside the same claim.
    var chatgptPlanType: String?

    /// Decodes the payload segment of a compact JWT. Returns `nil` when the
    /// token does not have three dot-separated segments or the payload is not
    /// a JSON object; a token missing individual claims still decodes.
    static func decode(_ token: String) -> JWTClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let data = base64URLDecode(String(segments[1])) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var claims = JWTClaims()
        claims.email = object["email"] as? String
        if let exp = object["exp"] as? NSNumber {
            claims.exp = Date(timeIntervalSince1970: exp.doubleValue)
        }
        if let auth = object["https://api.openai.com/auth"] as? [String: Any] {
            claims.chatgptAccountID = auth["chatgpt_account_id"] as? String
            claims.chatgptPlanType = auth["chatgpt_plan_type"] as? String
        }
        return claims
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
