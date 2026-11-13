import XCTest
@testable import Throttle

/// ISC-528: a development build never checks for, downloads or installs an
/// update; an update would replace the installed release from a development
/// copy.
@MainActor
final class DevelopmentBuildUpdateTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() async throws {
        cacheDirectory = try UpdateFixtures.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func testRestrictedControllerMakesNoCalls() async {
        let client = AuthMockHTTPClient(results: [.success(AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: "v0.2.0", size: 64)))])
        let downloader = MockDownloader()
        let verifier = MockVerifier()
        let installer = MockInstaller()
        let controller = UpdateController(
            client: client,
            downloader: downloader,
            verifier: verifier,
            installer: installer,
            currentVersion: SemanticVersion("0.1.0"),
            cacheDirectory: cacheDirectory,
            restriction: AppIdentity.developmentBuildRestriction
        )

        await controller.checkForUpdates().value
        await controller.installUpdate().value
        await controller.retry().value

        XCTAssertEqual(client.requests.count, 0)
        XCTAssertEqual(downloader.count, 0)
        XCTAssertEqual(verifier.verifications.count, 0)
        XCTAssertEqual(installer.installs.count, 0)
        XCTAssertEqual(installer.relaunchCount, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path), [])
    }

    func testTheIdentityDecidesTheRestriction() {
        XCTAssertEqual(UpdateController(identity: .development).restriction, "Not available in a development build")
        XCTAssertNil(UpdateController(identity: .release).restriction)
    }

    func testDevelopmentModelOffersNoUpdates() throws {
        let harness = try IdentityHarness()
        defer { harness.cleanUp() }
        XCTAssertEqual(harness.model(identity: .development).updates.restriction, AppIdentity.developmentBuildRestriction)
        XCTAssertNil(harness.model(identity: .release).updates.restriction)
    }
}
