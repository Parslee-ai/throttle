import XCTest
@testable import Throttle

@MainActor
final class AppSettingsTests: XCTestCase {
    /// A fresh, isolated defaults suite per test, removed when the test ends.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ai.parslee.throttle.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testDefaults() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(settings.pollInterval, 300)
        XCTAssertEqual(settings.rotationInterval, 10)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.accountMeta.isEmpty)
    }

    func testPollIntervalClampsOnSetAndOnLoad() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.pollInterval = 10
        XCTAssertEqual(settings.pollInterval, 60)
        settings.pollInterval = 10_000
        XCTAssertEqual(settings.pollInterval, 1_800)
        settings.pollInterval = .nan
        XCTAssertEqual(settings.pollInterval, 300)

        defaults.set(5.0, forKey: AppSettings.Key.pollInterval)
        XCTAssertEqual(AppSettings(defaults: defaults).pollInterval, 60)
    }

    func testRotationIntervalClamps() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.rotationInterval = 1
        XCTAssertEqual(settings.rotationInterval, 5)
        settings.rotationInterval = 500
        XCTAssertEqual(settings.rotationInterval, 60)
        defaults.set(999.0, forKey: AppSettings.Key.rotationInterval)
        XCTAssertEqual(AppSettings(defaults: defaults).rotationInterval, 60)
    }

    func testValuesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.pollInterval = 600
        settings.rotationInterval = 15
        let id = UUID()
        settings.setPlanLabel("Max", for: id)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pollInterval, 600)
        XCTAssertEqual(reloaded.rotationInterval, 15)
        XCTAssertEqual(reloaded.planLabel(for: id), "Max")
        reloaded.removeMeta(for: id)
        XCTAssertNil(AppSettings(defaults: defaults).planLabel(for: id))
    }

    func testPollSettingsCarriesTheInterval() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.pollInterval = 120
        XCTAssertEqual(settings.pollSettings.pollInterval, 120)
    }
}
