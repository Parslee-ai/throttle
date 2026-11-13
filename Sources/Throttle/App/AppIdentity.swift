import Foundation

/// Which copy of Throttle is running, and every place that copy may keep
/// state, all derived from its bundle identifier.
///
/// The release and a development build must never share a Keychain service,
/// a data folder or an update cache: a development copy that reads the real
/// accounts can rotate a refresh token the release still holds and sign the
/// real app out. Only the exact release identifier gets the release's
/// locations; anything else, a missing identifier included, is treated as a
/// development build, so an unexpected identity fails closed.
struct AppIdentity: Sendable, Hashable {
    static let releaseBundleIdentifier = "ai.parslee.throttle"
    static let developmentBundleIdentifier = "ai.parslee.throttle.dev"

    /// The reason a control that a development build must not use is disabled.
    static let developmentBuildRestriction = "Not available in a development build"

    static let release = AppIdentity(bundleIdentifier: releaseBundleIdentifier)
    static let development = AppIdentity(bundleIdentifier: developmentBundleIdentifier)

    /// The identity of the running app.
    static var current: AppIdentity {
        AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    let bundleIdentifier: String

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier ?? Self.developmentBundleIdentifier
    }

    var isDevelopmentBuild: Bool {
        bundleIdentifier != Self.releaseBundleIdentifier
    }

    /// The Keychain service every credential of this copy lives under.
    var keychainService: String {
        bundleIdentifier
    }

    /// The folder under Application Support that holds this copy's files.
    var dataFolderName: String {
        isDevelopmentBuild ? "Throttle Dev" : "Throttle"
    }

    /// This copy's data folder inside `applicationSupport`.
    func dataDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// Where this copy downloads update packages inside `caches`.
    func updateCacheDirectory(in caches: URL) -> URL {
        caches
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }
}

/// The user's Library folders that `AppIdentity` places its locations in.
/// Injectable so a test can stand up a whole home folder of its own.
struct UserDirectories: Sendable, Hashable {
    let applicationSupport: URL
    let caches: URL

    /// The running user's real folders.
    static var current: UserDirectories {
        let fm = FileManager.default
        return UserDirectories(
            applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        )
    }

    /// The folders as they sit under a home directory.
    init(home: URL) {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        self.init(
            applicationSupport: library.appendingPathComponent("Application Support", isDirectory: true),
            caches: library.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }
}
