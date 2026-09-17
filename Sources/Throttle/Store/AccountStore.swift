import Foundation
import os

/// Something went wrong in the non-secret account store.
enum AccountStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No account with this id exists.
    case unknownAccount(UUID)
    /// The encoder produced a string longer than the cap. Nothing legitimate in
    /// `accounts.json` is that long; a token is. The write is refused (ISC-95).
    case stringTooLong(length: Int, limit: Int)
    /// A POSIX call failed. `operation` names it, `errno` is the code.
    case posixFailure(operation: String, errno: Int32)

    var description: String {
        switch self {
        case .unknownAccount(let id):
            return "No account with id \(id.uuidString)"
        case .stringTooLong(let length, let limit):
            return "Refused to write accounts.json: a string of \(length) characters exceeds the \(limit) character limit"
        case .posixFailure(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

/// The source of truth for which accounts exist and in what order.
///
/// Two backing stores, each holding exactly one half of an account:
/// - `accounts.json` under Application Support holds the non-secret `Account`
///   records (ISC-88). It is written atomically and with mode 0600 (ISC-94).
/// - The `CredentialStore` (the Keychain in production) holds the tokens,
///   keyed by account id.
///
/// The actor keeps the account list in memory once loaded and rewrites the
/// whole file on every change. A malformed file is an error the caller sees;
/// it is never overwritten by an empty list.
actor AccountStore {
    /// Longest string `accounts.json` may contain (ISC-95).
    static let maximumStringLength = 200

    private let credentials: CredentialStore
    private let paths: AppPaths
    private let logger = Logger(subsystem: "ai.parslee.throttle", category: "AccountStore")

    private var storage: [Account] = []
    private var isLoaded = false

    init(credentials: CredentialStore, paths: AppPaths) {
        self.credentials = credentials
        self.paths = paths
    }

    // MARK: Reading

    /// Reads `accounts.json` into memory and returns the accounts in display
    /// order. A missing file means no accounts. A file that fails to decode
    /// throws, leaves the file on disk untouched, and leaves the store empty
    /// and unloaded, so later mutations also throw instead of wiping it.
    @discardableResult
    func load() throws -> [Account] {
        let url = paths.accountsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            storage = []
            isLoaded = true
            return []
        }
        let data = try Data(contentsOf: url)
        let decoded = try Self.decoder.decode([Account].self, from: data)
        storage = Self.sorted(decoded)
        isLoaded = true
        return storage
    }

    /// The accounts in display order: `sortIndex` ascending, ties by `addedAt`
    /// (ISC-92). Empty until `load()` has run.
    func accounts() -> [Account] {
        storage
    }

    /// The credential for an account, or `nil` when its Keychain item is gone.
    func credential(for id: UUID) throws -> AccountCredential? {
        try credentials.load(for: id)
    }

    /// Accounts whose Keychain item is absent. The UI shows these as
    /// `.needsLogin`; they are never dropped from the list (ISC-89). A Keychain
    /// read that fails for any other reason is also reported here, because the
    /// user's remedy is the same: sign in again.
    func missingCredentialIDs() -> [UUID] {
        storage.compactMap { account in
            do {
                return try credentials.load(for: account.id) == nil ? account.id : nil
            } catch {
                logger.error("Keychain read failed for account \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                return account.id
            }
        }
    }

    // MARK: Mutating

    /// Adds an account, or, when one with the same provider and email
    /// (case-insensitive) already exists, replaces that account's credential
    /// and adopts the new email casing while keeping its id and position
    /// (ISC-93).
    func add(provider: Provider, email: String, credential: AccountCredential) throws -> Account {
        try ensureLoaded()
        if let index = storage.firstIndex(where: {
            $0.provider == provider && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) {
            try credentials.save(credential, for: storage[index].id)
            storage[index].email = email
            try persist()
            return storage[index]
        }

        let nextIndex = (storage.map(\.sortIndex).max() ?? -1) + 1
        let account = Account(provider: provider, email: email, sortIndex: nextIndex)
        try credentials.save(credential, for: account.id)
        storage.append(account)
        try persist()
        return account
    }

    /// Removes the account's Keychain item and its `accounts.json` entry in one
    /// operation (ISC-91). The Keychain item goes first: if the file write then
    /// fails, the account is still listed and shows as needing login, which is
    /// recoverable. The reverse order could leave an orphaned token.
    func remove(id: UUID) throws {
        try ensureLoaded()
        guard let index = storage.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        try credentials.delete(for: id)
        let removed = storage.remove(at: index)
        do {
            try persist()
        } catch {
            storage.insert(removed, at: index)
            logger.error("Removed Keychain item for \(id.uuidString, privacy: .public) but failed to rewrite accounts.json: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Moves an account to `index` in display order (clamped to the valid
    /// range), renumbers every `sortIndex` to 0...n-1, and persists.
    func move(id: UUID, to index: Int) throws {
        try ensureLoaded()
        guard let from = storage.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        let account = storage.remove(at: from)
        let target = min(max(index, 0), storage.count)
        storage.insert(account, at: target)
        try renumberAndPersist()
    }

    /// Moves the account one position earlier. A no-op at the top.
    func moveUp(id: UUID) throws {
        try ensureLoaded()
        guard let from = storage.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        guard from > 0 else { return }
        storage.swapAt(from, from - 1)
        try renumberAndPersist()
    }

    /// Moves the account one position later. A no-op at the bottom.
    func moveDown(id: UUID) throws {
        try ensureLoaded()
        guard let from = storage.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        guard from < storage.count - 1 else { return }
        storage.swapAt(from, from + 1)
        try renumberAndPersist()
    }

    /// Updates the display email, for when a provider profile changes.
    func updateEmail(id: UUID, email: String) throws {
        try ensureLoaded()
        guard let index = storage.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        storage[index].email = email
        try persist()
    }

    /// Replaces the stored credential after a refresh rotated it. Nothing in
    /// `accounts.json` changes, so nothing is written there.
    func updateCredential(_ credential: AccountCredential, for id: UUID) throws {
        try ensureLoaded()
        guard storage.contains(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount(id)
        }
        try credentials.save(credential, for: id)
    }

    // MARK: Persistence

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.addedAt < $1.addedAt
        }
    }

    private func ensureLoaded() throws {
        if !isLoaded { try load() }
    }

    private func renumberAndPersist() throws {
        for index in storage.indices {
            storage[index].sortIndex = index
        }
        try persist()
    }

    /// Encodes the account list and writes it. Refuses to write when any string
    /// in the output exceeds `maximumStringLength` (ISC-95).
    private func persist() throws {
        let data = try Self.encode(storage)
        try paths.ensureDirectoryExists()
        try Self.atomicWrite(data, to: paths.accountsFile)
    }

    /// The encoder path. Exposed to tests so they can assert the length guard
    /// on the exact bytes that would land on disk.
    static func encode(_ accounts: [Account]) throws -> Data {
        let data = try encoder.encode(accounts)
        let object = try JSONSerialization.jsonObject(with: data)
        try assertNoLongStrings(in: object)
        return data
    }

    private static func assertNoLongStrings(in value: Any) throws {
        switch value {
        case let string as String:
            if string.count > maximumStringLength {
                throw AccountStoreError.stringTooLong(length: string.count, limit: maximumStringLength)
            }
        case let array as [Any]:
            for element in array { try assertNoLongStrings(in: element) }
        case let dictionary as [String: Any]:
            for (key, element) in dictionary {
                if key.count > maximumStringLength {
                    throw AccountStoreError.stringTooLong(length: key.count, limit: maximumStringLength)
                }
                try assertNoLongStrings(in: element)
            }
        default:
            break
        }
    }

    /// Writes to `<name>.tmp` beside the target, then `rename(2)`s over it, so
    /// a crash mid-write leaves the previous file intact (ISC-88). Mode 0600 is
    /// set on the temp file before the rename and re-applied to the final path
    /// afterwards (ISC-94).
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AccountStoreError.posixFailure(operation: "create \(tmp.lastPathComponent)", errno: errno)
        }
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw AccountStoreError.posixFailure(operation: "rename", errno: code)
        }
        guard chmod(url.path, 0o600) == 0 else {
            throw AccountStoreError.posixFailure(operation: "chmod", errno: errno)
        }
    }
}
