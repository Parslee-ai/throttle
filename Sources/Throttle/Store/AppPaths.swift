import Foundation

/// Where Throttle keeps its non-secret files on disk.
///
/// The files are `accounts.json` and `status-cache.json`. Secrets never live under this
/// directory; they live in the Keychain (see `KeychainStore`). The base
/// directory is injectable so tests run against a temporary directory and
/// never touch the real `~/Library/Application Support/Throttle`.
struct AppPaths: Sendable, Hashable {
    /// The directory that holds every file Throttle writes.
    /// Standard location: `~/Library/Application Support/Throttle`.
    let applicationSupportDirectory: URL

    /// The non-secret account list, a JSON array of `Account`.
    var accountsFile: URL {
        applicationSupportDirectory.appendingPathComponent("accounts.json", isDirectory: false)
    }

    /// The last known status per account, a JSON object of `CachedStatus`
    /// keyed by account id (ISC-90). Never holds a token.
    var statusCacheFile: URL {
        applicationSupportDirectory.appendingPathComponent("status-cache.json", isDirectory: false)
    }

    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    /// The real location used by the running app.
    static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(applicationSupportDirectory: base.appendingPathComponent("Throttle", isDirectory: true))
    }

    /// Creates the application support directory on first use with mode 0700,
    /// so no other user on the machine can list or read what Throttle stores.
    /// Safe to call repeatedly.
    func ensureDirectoryExists() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: applicationSupportDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try fm.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
