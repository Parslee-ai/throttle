import XCTest
@testable import Throttle

/// ISC-527: a development build never registers or unregisters launch at
/// login, so a stale copy in a build folder can never start at login.
@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private var harness: IdentityHarness!

    override func setUp() async throws {
        harness = try IdentityHarness()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    func testDevelopmentBuildNeverTouchesTheLoginItem() {
        let model = harness.model(identity: .development)
        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)
        model.refreshLaunchAtLoginStatus()

        XCTAssertEqual(harness.loginItems.registers, 0)
        XCTAssertEqual(harness.loginItems.unregisters, 0)
        XCTAssertEqual(harness.loginItems.calls, 0)
        XCTAssertEqual(model.launchAtLoginStatus, .notRegistered)
        XCTAssertFalse(model.settings.launchAtLogin)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.launchAtLoginRestriction, "Not available in a development build")
    }

    func testDevelopmentBuildStartsWithoutTouchingTheLoginItem() async {
        let model = harness.model(identity: .development)
        await model.start().value
        await model.stop()
        XCTAssertEqual(harness.loginItems.calls, 0)
    }

    /// The control: the release registers and unregisters through the same
    /// service.
    func testReleaseBuildRegistersAndUnregisters() {
        let model = harness.model(identity: .release)
        XCTAssertNil(model.launchAtLoginRestriction)

        model.setLaunchAtLogin(true)
        XCTAssertEqual(harness.loginItems.registers, 1)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)
        XCTAssertTrue(model.settings.launchAtLogin)

        model.setLaunchAtLogin(false)
        XCTAssertEqual(harness.loginItems.unregisters, 1)
        XCTAssertEqual(model.launchAtLoginStatus, .notRegistered)
        XCTAssertFalse(model.settings.launchAtLogin)
    }
}
