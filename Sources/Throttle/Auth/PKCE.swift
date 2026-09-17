import CryptoKit
import Foundation
import Security

/// A PKCE verifier and its S256 challenge (RFC 7636).
///
/// The verifier lives in memory for the duration of one login and is never
/// written anywhere (ISC-134). It is captured by the login session's completion
/// closure and released with it.
struct PKCEPair: Sendable {
    let verifier: String
    let challenge: String
}

enum PKCE {
    /// Generates a verifier from 64 bytes of `SecRandomCopyBytes` output
    /// (86 base64url characters, within the 43...128 range RFC 7636 allows)
    /// and its S256 challenge.
    static func generate() -> PKCEPair {
        let verifier = base64URL(randomBytes(64))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// A 32-byte random `state` value, base64url encoded.
    static func randomState() -> String {
        base64URL(randomBytes(32))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, the S256 transform.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without padding, as RFC 7636 requires.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Cryptographically secure random bytes from the system RNG. A failure
    /// here means the system RNG is unavailable, which is not a condition an
    /// OAuth login can proceed under, so it is a hard stop rather than a
    /// silently weaker verifier.
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes)
    }
}
