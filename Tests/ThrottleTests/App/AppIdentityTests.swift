import XCTest
@testable import Throttle

/// ISC-525 and ISC-529: one bundle identifier decides the Keychain service,
/// the data folder and the update cache, and the release keeps exactly the
/// values it shipped with.
final class AppIdentityTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/example/Library", isDirectory: true)

    private var applicationSupport: URL { base.appendingPathComponent("Application Support", isDirectory: true) }
    private var caches: URL { base.appendingPathComponent("Caches", isDirectory: true) }

    func testReleaseDerivesTheShippedLocations() {
        let identity = AppIdentity(bundleIdentifier: "ai.parslee.throttle")
        XCTAssertEqual(identity, .release)
        XCTAssertFalse(identity.isDevelopmentBuild)
        XCTAssertEqual(identity.keychainService, "ai.parslee.throttle")
        XCTAssertEqual(identity.dataFolderName, "Throttle")
        XCTAssertEqual(
            identity.dataDirectory(in: applicationSupport).path,
            "/Users/example/Library/Application Support/Throttle"
        )
        XCTAssertEqual(
            identity.updateCacheDirectory(in: caches).path,
            "/Users/example/Library/Caches/ai.parslee.throttle/Updates"
        )
    }

    func testDevelopmentDerivesLocationsOfItsOwn() {
        let identity = AppIdentity(bundleIdentifier: "ai.parslee.throttle.dev")
        XCTAssertEqual(identity, .development)
        XCTAssertTrue(identity.isDevelopmentBuild)
        XCTAssertEqual(identity.keychainService, "ai.parslee.throttle.dev")
        XCTAssertEqual(identity.dataFolderName, "Throttle Dev")
        XCTAssertEqual(
            identity.dataDirectory(in: applicationSupport).path,
            "/Users/example/Library/Application Support/Throttle Dev"
        )
        XCTAssertEqual(
            identity.updateCacheDirectory(in: caches).path,
            "/Users/example/Library/Caches/ai.parslee.throttle.dev/Updates"
        )
    }

    /// Nothing a development build derives may equal or sit inside a release
    /// location, or the two copies would share state again.
    func testDevelopmentLocationsNeverOverlapTheRelease() {
        let release = AppIdentity.release
        let development = AppIdentity.development
        XCTAssertNotEqual(development.keychainService, release.keychainService)

        let releaseData = release.dataDirectory(in: applicationSupport).path + "/"
        let developmentPaths = AppPaths.standard(for: development, in: UserDirectories(applicationSupport: applicationSupport, caches: caches))
        for file in [developmentPaths.accountsFile, developmentPaths.statusCacheFile,
                     developmentPaths.rateLimitsFile, developmentPaths.diagnosticsFile] {
            XCTAssertFalse(file.path.hasPrefix(releaseData), file.path)
        }

        let releaseCache = release.updateCacheDirectory(in: caches).path + "/"
        XCTAssertFalse((development.updateCacheDirectory(in: caches).path + "/").hasPrefix(releaseCache))
    }

    /// Only the exact release identifier gets release locations; a missing or
    /// unexpected identifier fails closed.
    func testAnythingButTheReleaseIdentifierIsADevelopmentBuild() {
        for identifier in [nil, "", "ai.parslee.throttle.tests", "AI.PARSLEE.THROTTLE", "com.example.other"] {
            let identity = AppIdentity(bundleIdentifier: identifier)
            XCTAssertTrue(identity.isDevelopmentBuild, identifier ?? "nil")
            XCTAssertNotEqual(identity.keychainService, "ai.parslee.throttle", identifier ?? "nil")
            XCTAssertEqual(identity.dataFolderName, "Throttle Dev", identifier ?? "nil")
        }
        XCTAssertEqual(AppIdentity(bundleIdentifier: nil).bundleIdentifier, "ai.parslee.throttle.dev")
    }

    func testAppPathsFollowTheIdentity() {
        let directories = UserDirectories(applicationSupport: applicationSupport, caches: caches)
        XCTAssertEqual(
            AppPaths.standard(for: .release, in: directories).accountsFile.path,
            "/Users/example/Library/Application Support/Throttle/accounts.json"
        )
        XCTAssertEqual(
            AppPaths.standard(for: .development, in: directories).accountsFile.path,
            "/Users/example/Library/Application Support/Throttle Dev/accounts.json"
        )
    }

    /// The unit tests run inside the Debug app, so the running identity here
    /// is the Debug build's.
    func testTheDebugHostRunsUnderTheDevelopmentIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "ai.parslee.throttle.dev")
        XCTAssertEqual(AppIdentity.current, .development)
    }

    /// An update must be the release product whatever copy checks for it.
    func testPackageIdentifierStaysTheRelease() {
        XCTAssertEqual(PackageVerifier.productIdentifier, AppIdentity.releaseBundleIdentifier)
    }

    func testUserDirectoriesUnderAHome() {
        let directories = UserDirectories(home: URL(fileURLWithPath: "/Users/example", isDirectory: true))
        XCTAssertEqual(directories.applicationSupport.path, "/Users/example/Library/Application Support")
        XCTAssertEqual(directories.caches.path, "/Users/example/Library/Caches")
    }
}
