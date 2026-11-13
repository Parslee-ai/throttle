import XCTest
@testable import Throttle

/// ISC-526: a development build started as a normal app on a Mac that holds
/// real accounts reads none of them. The home folder is a temporary one that
/// holds a release store written by the release's own `AccountStore`.
@MainActor
final class DevelopmentBuildStoreTests: XCTestCase {
    private var harness: IdentityHarness!

    override func setUp() async throws {
        harness = try IdentityHarness()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    /// Writes one account the way the release does and returns its folder.
    private func writeReleaseStore() async throws -> URL {
        let paths = AppPaths.standard(for: .release, in: harness.directories)
        let store = AccountStore(credentials: InMemoryCredentialStore(), paths: paths)
        _ = try await store.add(
            provider: .anthropic,
            email: "someone@example.com",
            credential: AccountCredential(
                accessToken: FakeToken.anthropicAccess,
                refreshToken: FakeToken.anthropicRefresh,
                expiresAt: Date().addingTimeInterval(3_600),
                scopes: ["usage"]
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.accountsFile.path))
        return paths.applicationSupportDirectory
    }

    /// Every file in a folder with its bytes and modification date.
    private func contents(of folder: URL) throws -> [String: (Data, Date)] {
        let fm = FileManager.default
        var result: [String: (Data, Date)] = [:]
        for name in try fm.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            let modified = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
            result[name] = (try Data(contentsOf: url), modified)
        }
        return result
    }

    func testDevelopmentBuildLoadsNoneOfTheReleaseAccounts() async throws {
        let releaseFolder = try await writeReleaseStore()
        let before = try contents(of: releaseFolder)
        XCTAssertEqual(Set(before.keys), ["accounts.json"])

        var services: [String] = []
        let model = harness.model(identity: .development, requestedServices: &services)
        await model.start().value
        await model.stop()

        XCTAssertTrue(model.accounts.isEmpty, "the add-account state, not the release's accounts")
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertEqual(services, ["ai.parslee.throttle.dev"], "only the development Keychain service is opened")
        XCTAssertEqual(harness.credentials.calls, 0, "no Keychain item is read")
        XCTAssertEqual(harness.loginItems.calls, 0)

        let after = try contents(of: releaseFolder)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "nothing is added to the release folder")
        for (name, (data, modified)) in before {
            XCTAssertEqual(after[name]?.0, data, "\(name) is unchanged")
            XCTAssertEqual(after[name]?.1, modified, "\(name) is not rewritten")
        }

        let developmentFolder = AppPaths.standard(for: .development, in: harness.directories).applicationSupportDirectory
        XCTAssertNotEqual(developmentFolder.standardizedFileURL, releaseFolder.standardizedFileURL)
        XCTAssertEqual(developmentFolder.deletingLastPathComponent().standardizedFileURL,
                       releaseFolder.deletingLastPathComponent().standardizedFileURL)
    }

    /// The control: the same home under the release identity does load the
    /// account, so the test above proves separation, not a broken store.
    func testReleaseBuildLoadsItsOwnAccounts() async throws {
        _ = try await writeReleaseStore()

        var services: [String] = []
        let model = harness.model(identity: .release, requestedServices: &services)
        await model.start().value
        await model.stop()

        XCTAssertEqual(model.accounts.map(\.email), ["someone@example.com"])
        XCTAssertEqual(services, ["ai.parslee.throttle"])
    }
}
