import Foundation
import ServiceManagement
import XCTest
@testable import Throttle

/// A login item that records every call and never reaches macOS.
@MainActor
final class RecordingLoginItems: LoginItemService {
    private(set) var registers = 0
    private(set) var unregisters = 0
    private(set) var statusReads = 0
    private var current: SMAppService.Status = .notRegistered

    var calls: Int { registers + unregisters + statusReads }

    var status: SMAppService.Status {
        statusReads += 1
        return current
    }

    func register() throws {
        registers += 1
        current = .enabled
    }

    func unregister() throws {
        unregisters += 1
        current = .notRegistered
    }
}

/// An in-memory credential store that counts every call.
final class RecordingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = InMemoryCredentialStore()
    private var counts = (saves: 0, loads: 0, deletes: 0)

    var calls: Int { lock.withLock { counts.saves + counts.loads + counts.deletes } }

    func save(_ credential: AccountCredential, for accountID: UUID) throws {
        lock.withLock { counts.saves += 1 }
        try inner.save(credential, for: accountID)
    }

    func load(for accountID: UUID) throws -> AccountCredential? {
        lock.withLock { counts.loads += 1 }
        return try inner.load(for: accountID)
    }

    func delete(for accountID: UUID) throws {
        lock.withLock { counts.deletes += 1 }
        try inner.delete(for: accountID)
    }
}

/// A temporary home folder, and an `AppModel` built the way the app builds
/// one but over that home, with recorded login items and credentials.
@MainActor
struct IdentityHarness {
    let home: URL
    let directories: UserDirectories
    let loginItems = RecordingLoginItems()
    let credentials = RecordingCredentialStore()
    let defaultsSuite = "ThrottleTests-\(UUID().uuidString)"

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        directories = UserDirectories(home: home)
    }

    /// The model through the app's own convenience initializer. The services
    /// it asks the credential factory for are appended to `requestedServices`.
    func model(identity: AppIdentity, requestedServices: inout [String]) -> AppModel {
        let credentials = credentials
        return AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: defaultsSuite)!),
            identity: identity,
            directories: directories,
            credentials: { service in
                requestedServices.append(service)
                return credentials
            },
            loginItems: loginItems
        )
    }

    func model(identity: AppIdentity) -> AppModel {
        var ignored: [String] = []
        return model(identity: identity, requestedServices: &ignored)
    }

    func cleanUp() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: home)
    }
}
