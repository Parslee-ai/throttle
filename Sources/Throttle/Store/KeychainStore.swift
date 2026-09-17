import Foundation
import Security

/// Storage for the secret half of an account.
///
/// The production conformer is `KeychainStore`. Tests and SwiftUI previews use
/// `InMemoryCredentialStore` so they never touch the user's Keychain.
protocol CredentialStore: Sendable {
    /// Stores or replaces the credential for an account.
    func save(_ credential: AccountCredential, for accountID: UUID) throws
    /// Returns the stored credential, or `nil` when none exists.
    func load(for accountID: UUID) throws -> AccountCredential?
    /// Removes the credential. Removing one that does not exist is not an error.
    func delete(for accountID: UUID) throws
}

/// A Keychain call failed with an `OSStatus` other than "not found".
struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}

/// `AccountCredential` as it is written to the Keychain.
///
/// This is the ONLY place in Throttle where a credential is serialised.
/// `AccountCredential` itself is deliberately not `Codable`, so a token cannot
/// drift into `accounts.json`, a log, or a plist by way of an innocent
/// `JSONEncoder().encode(...)`. The mirror lives here, private to the file, and
/// its output goes to one destination: a generic-password item in the Keychain.
private struct StoredCredential: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var accountID: String?
    var scopes: [String]

    init(_ credential: AccountCredential) {
        accessToken = credential.accessToken
        refreshToken = credential.refreshToken
        expiresAt = credential.expiresAt
        accountID = credential.accountID
        scopes = credential.scopes
    }

    var credential: AccountCredential {
        AccountCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountID: accountID,
            scopes: scopes
        )
    }
}

/// Holds account credentials as generic-password items in the user's login
/// Keychain, one item per account.
///
/// Item layout (ISC-61):
/// - service: `ai.parslee.throttle`
/// - account: the account's UUID string
/// - value: JSON of the credential (access token, refresh token, expiry,
///   provider account id, scopes) as one blob
///
/// Item attributes (ISC-66):
/// - `kSecAttrAccessibleAfterFirstUnlock`: readable by a background poll once
///   the user has unlocked the Mac after boot, never before.
/// - `kSecAttrSynchronizable = false`: no iCloud Keychain sync. A refresh token
///   that rotates on two Macs at once bricks the account on both.
/// - `kSecUseDataProtectionKeychain = false`: the file-based login keychain.
///   The data-protection keychain requires a keychain-access-group entitlement
///   and a provisioning profile, which a Developer ID app distributed outside
///   the App Store does not carry. The login keychain gives the same per-app
///   ACL (only this signed binary reads the item without a prompt) and is what
///   `security find-generic-password` inspects, which the tests rely on.
///
/// Throttle only ever touches items under its own service (ISC-137). It never
/// queries another app's items; the explicit import flows copy once from a
/// user-selected source and never write back.
final class KeychainStore: CredentialStore {
    /// The Keychain service name for every Throttle credential.
    static let service = "ai.parslee.throttle"

    private let service: String

    /// - Parameter service: overridable so the integration test can use a
    ///   throwaway service and leave the real items alone.
    init(service: String = KeychainStore.service) {
        self.service = service
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func baseQuery(for accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: kCFBooleanFalse!,
        ]
    }

    /// Upsert: update the existing item, and add it when there is none.
    func save(_ credential: AccountCredential, for accountID: UUID) throws {
        let data = try Self.encoder.encode(StoredCredential(credential))
        let query = baseQuery(for: accountID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            addQuery[kSecAttrLabel as String] = "Throttle account \(accountID.uuidString)"
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func load(for accountID: UUID) throws -> AccountCredential? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return try Self.decoder.decode(StoredCredential.self, from: data).credential
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Idempotent: a missing item is treated as already deleted.
    func delete(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// A `CredentialStore` that keeps credentials in a dictionary. For tests and
/// previews only; nothing here survives the process.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: AccountCredential] = [:]

    init() {}

    func save(_ credential: AccountCredential, for accountID: UUID) throws {
        lock.withLock { storage[accountID] = credential }
    }

    func load(for accountID: UUID) throws -> AccountCredential? {
        lock.withLock { storage[accountID] }
    }

    func delete(for accountID: UUID) throws {
        lock.withLock { _ = storage.removeValue(forKey: accountID) }
    }

    /// The ids that currently hold a credential. Test convenience.
    var storedIDs: Set<UUID> {
        lock.withLock { Set(storage.keys) }
    }
}
