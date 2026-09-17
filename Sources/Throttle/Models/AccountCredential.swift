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

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountID: String? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.scopes = scopes
    }
}

extension AccountCredential: CustomStringConvertible, CustomDebugStringConvertible {
    /// Interpolating a credential must never print a token, including from a
    /// debugger or an accidental `String(describing:)` in an error path.
    var description: String { "AccountCredential(redacted)" }
    var debugDescription: String { description }
}
