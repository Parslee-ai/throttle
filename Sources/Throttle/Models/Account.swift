import Foundation

/// The non-secret record of one signed-in account.
///
/// This type is what gets written to `accounts.json`. It deliberately carries no
/// access token, refresh token, or expiry: those live only in the Keychain, as
/// `AccountCredential`. Adding a token-bearing property here would leak secrets
/// to disk in plain text, and `AccountCodingTests` fails the build if one appears.
struct Account: Codable, Identifiable, Hashable, Sendable {
    /// Stable local identifier. Also the Keychain account name for the credential.
    let id: UUID
    let provider: Provider
    /// Display label for the account, populated from the provider's profile.
    var email: String
    /// User-controlled display order, ascending. Ties break by `addedAt`.
    var sortIndex: Int
    let addedAt: Date

    init(
        id: UUID = UUID(),
        provider: Provider,
        email: String,
        sortIndex: Int,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }
}
