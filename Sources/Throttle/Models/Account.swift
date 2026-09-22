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
    /// The account's email, populated from the provider's profile.
    var email: String
    /// A name the user chose for the account, or `nil` for none. Optional so
    /// an `accounts.json` written before renaming existed still decodes.
    var nickname: String?
    /// User-controlled display order, ascending. Ties break by `addedAt`.
    var sortIndex: Int
    let addedAt: Date

    init(
        id: UUID = UUID(),
        provider: Provider,
        email: String,
        nickname: String? = nil,
        sortIndex: Int,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.nickname = nickname
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }

    /// What every view calls the account: the nickname when one is set,
    /// otherwise the email.
    var displayName: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname
        }
        return email
    }
}
