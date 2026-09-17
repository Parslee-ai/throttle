import Foundation

/// The secret half of an account, held only in memory and in the Keychain.
///
/// Provider-agnostic on purpose: both OAuth flows produce the same fields, so
/// the store and the refresh doctrine are written once. This type is not
/// `Codable` by design, to keep it from being serialised into the non-secret
/// account store by accident.
struct AccountCredential: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// The provider's own account identifier, when it issues one.
    var accountID: String?
    var scopes: [String]
    /// When the refresh token itself expires, from `refresh_token_expires_in`
    /// (ISC-61). `nil` when the provider does not say.
    var refreshTokenExpiresAt: Date?
    /// The OpenID `id_token` from the last exchange, when the provider issues
    /// one (ISC-81). Stored alongside the other tokens, never parsed by the UI.
    var idToken: String?

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountID: String? = nil,
        scopes: [String] = [],
        refreshTokenExpiresAt: Date? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.scopes = scopes
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.idToken = idToken
    }
}

extension AccountCredential: CustomStringConvertible, CustomDebugStringConvertible {
    /// Interpolating a credential must never print a token, including from a
    /// debugger or an accidental `String(describing:)` in an error path.
    var description: String { "AccountCredential(redacted)" }
    var debugDescription: String { description }
}
