import XCTest
@testable import Throttle

@MainActor
final class UpdateControllerTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() async throws {
        cacheDirectory = try UpdateFixtures.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private struct Harness {
        let controller: UpdateController
        let client: AuthMockHTTPClient
        let downloader: MockDownloader
        let verifier: MockVerifier
        let installer: MockInstaller
    }

    private func harness(
        current: String? = "0.1.0",
        responses: [Result<HTTPResponse, Error>] = [.success(AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: "v0.2.0", size: 64)))]
    ) -> Harness {
        let client = AuthMockHTTPClient(results: responses)
        let downloader = MockDownloader()
        let verifier = MockVerifier()
        let installer = MockInstaller()
        let controller = UpdateController(
            client: client,
            downloader: downloader,
            verifier: verifier,
            installer: installer,
            currentVersion: current.flatMap(SemanticVersion.init),
            cacheDirectory: cacheDirectory
        )
        return Harness(controller: controller, client: client, downloader: downloader, verifier: verifier, installer: installer)
    }

    // MARK: No automatic traffic

    func testCreatingTheControllerTouchesNothing() {
        let h = harness()
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.client.requests.count, 0, "no launch-time check")
        XCTAssertEqual(h.downloader.count, 0)
    }

    // MARK: Checking

    func testUpToDate() async {
        let h = harness(responses: [.success(AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: "v0.1.0")))])
        await h.controller.checkForUpdates().value
        XCTAssertEqual(h.controller.state, .upToDate("0.1.0"))
        XCTAssertEqual(h.client.requests.count, 1)
    }

    func testCheckingIsSingleFlight() async {
        let h = harness()
        let first = h.controller.checkForUpdates()
        XCTAssertEqual(h.controller.state, .checking)
        h.controller.checkForUpdates()
        h.controller.installUpdate()
        await first.value
        XCTAssertEqual(h.client.requests.count, 1)
        XCTAssertEqual(h.controller.state, .available("0.2.0"))
    }

    func testUnknownCurrentVersionFailsWithoutARequest() async {
        let h = harness(current: nil)
        await h.controller.checkForUpdates().value
        XCTAssertEqual(h.controller.state, .failed(UpdateError.unknownCurrentVersion.userMessage, canOpenInInstaller: false))
        XCTAssertEqual(h.client.requests.count, 0)
    }

    func testRateLimitedCheckFailsReadably() async {
        let h = harness(responses: [.success(HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data()))])
        await h.controller.checkForUpdates().value
        guard case .failed(let message, let canOpen) = h.controller.state else {
            return XCTFail("got \(h.controller.state)")
        }
        XCTAssertTrue(message.contains("Try again in 1 minute."), message)
        XCTAssertFalse(canOpen)
    }

    func testNetworkFailureIsRedacted() async {
        struct Leaky: Error, LocalizedError {
            var errorDescription: String? { "request failed with Authorization: Bearer abc.def.ghi" }
        }
        let h = harness(responses: [.failure(Leaky())])
        await h.controller.checkForUpdates().value
        guard case .failed(let message, _) = h.controller.state else { return XCTFail("got \(h.controller.state)") }
        XCTAssertFalse(message.contains("abc.def.ghi"), message)
        XCTAssertTrue(message.contains("[redacted]"), message)
    }

    // MARK: Installing

    func testAvailableThenInstallThenRelaunch() async throws {
        let h = harness()
        await h.controller.checkForUpdates().value
        XCTAssertEqual(h.controller.state, .available("0.2.0"))

        await h.controller.installUpdate().value

        XCTAssertEqual(h.controller.state, .relaunching)
        XCTAssertEqual(h.downloader.count, 1)
        let verification = try XCTUnwrap(h.verifier.verifications.first)
        XCTAssertEqual(verification.0.lastPathComponent, "Throttle-0.2.0.pkg")
        XCTAssertEqual(verification.1, UpdateFixtures.team)
        let install = try XCTUnwrap(h.installer.installs.first)
        XCTAssertEqual(install.0, verification.0, "installs exactly the file that was verified")
        XCTAssertEqual(install.1, "0.2.0")
        XCTAssertEqual(install.2, UpdateFixtures.team)
        XCTAssertEqual(h.installer.relaunchCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.0.path), "the installed package is cleaned up")
    }

    func testInstallWithoutAnAvailableUpdateDoesNothing() async {
        let h = harness(responses: [.success(AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: "v0.1.0")))])
        await h.controller.installUpdate().value
        XCTAssertEqual(h.controller.state, .idle)
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        XCTAssertEqual(h.controller.state, .upToDate("0.1.0"))
        XCTAssertEqual(h.downloader.count, 0)
    }

    func testCancelledPromptShowsCancelledAndCanInstallAgain() async {
        let h = harness()
        h.installer.outcomes = [.cancel, .success]
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        XCTAssertEqual(h.controller.state, .cancelled)
        XCTAssertEqual(h.installer.relaunchCount, 0)

        await h.controller.installUpdate().value
        XCTAssertEqual(h.controller.state, .relaunching)
        XCTAssertEqual(h.installer.installs.count, 2)
    }

    func testInstallFailureIsRedactedAndOffersInstaller() async {
        let h = harness()
        h.installer.outcomes = [.fail("installer said Bearer sk-live-secret-token-value")]
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value

        guard case .failed(let message, let canOpen) = h.controller.state else {
            return XCTFail("got \(h.controller.state)")
        }
        XCTAssertTrue(message.hasPrefix("The update couldn't be installed:"), message)
        XCTAssertFalse(message.contains("sk-live-secret-token-value"), message)
        XCTAssertTrue(canOpen)
        XCTAssertEqual(h.installer.relaunchCount, 0)

        h.controller.openInInstaller()
        XCTAssertEqual(h.installer.openedPackages.map(\.lastPathComponent), ["Throttle-0.2.0.pkg"])
    }

    func testRetryAfterAnInstallFailureInstallsAgain() async {
        let h = harness()
        h.installer.outcomes = [.fail("disk full"), .success]
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        await h.controller.retry().value
        XCTAssertEqual(h.controller.state, .relaunching)
        XCTAssertEqual(h.client.requests.count, 1, "retrying an install does not re-check")
    }

    func testVerificationFailureNeverInstalls() async {
        let h = harness()
        h.verifier.verifyError = .verification("the package is signed by a different developer than this copy of Throttle")
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value

        guard case .failed(let message, let canOpen) = h.controller.state else {
            return XCTFail("got \(h.controller.state)")
        }
        XCTAssertTrue(message.contains("different developer"), message)
        XCTAssertFalse(canOpen, "an unverified package is never offered to Installer")
        XCTAssertEqual(h.installer.installs.count, 0)
        h.controller.openInInstaller()
        XCTAssertEqual(h.installer.openedPackages, [])
    }

    func testAnAdHocBuildIsRefusedBeforeDownloading() async {
        let h = harness()
        h.verifier.teamID = nil
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        XCTAssertEqual(h.controller.state, .failed(UpdateError.unsignedApp.userMessage, canOpenInInstaller: false))
        XCTAssertEqual(h.downloader.count, 0)
    }

    func testDownloadFailureFails() async {
        let h = harness()
        h.downloader.error = .download("received 10 bytes but the release lists 64")
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        guard case .failed(let message, false) = h.controller.state else { return XCTFail("got \(h.controller.state)") }
        XCTAssertTrue(message.contains("couldn't be downloaded"), message)
        XCTAssertEqual(h.verifier.verifications.count, 0)
    }

    func testRelaunchFailureSaysTheUpdateInstalled() async {
        let h = harness()
        h.installer.relaunchError = .relaunch("no /bin/sh")
        await h.controller.checkForUpdates().value
        await h.controller.installUpdate().value
        guard case .failed(let message, _) = h.controller.state else { return XCTFail("got \(h.controller.state)") }
        XCTAssertTrue(message.contains("The update was installed"), message)
    }

    // MARK: Current version

    func testEnvironmentOverrideWinsOnlyWhenValid() {
        let bundleVersion = UpdateController.resolveCurrentVersion(environment: [:])
        XCTAssertEqual(
            UpdateController.resolveCurrentVersion(environment: ["THROTTLE_UPDATE_CURRENT_VERSION": "0.0.1"]),
            SemanticVersion("0.0.1")
        )
        XCTAssertEqual(
            UpdateController.resolveCurrentVersion(environment: ["THROTTLE_UPDATE_CURRENT_VERSION": "0.1.0-rc.9"])?.text,
            "0.1.0-rc.9"
        )
        for bad in ["", "banana", "v0.0.1", "0.0.1\n", "0.0.1; rm -rf ~"] {
            XCTAssertEqual(
                UpdateController.resolveCurrentVersion(environment: ["THROTTLE_UPDATE_CURRENT_VERSION": bad]),
                bundleVersion,
                bad.debugDescription
            )
        }
    }

    func testBundleVersionIsTheDefault() {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(UpdateController.resolveCurrentVersion(environment: [:]), short.flatMap(SemanticVersion.init))
    }
}
