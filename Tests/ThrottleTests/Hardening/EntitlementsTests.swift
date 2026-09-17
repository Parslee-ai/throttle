import XCTest

/// ISC-132: Developer ID distribution, Hardened Runtime on, and exactly one
/// entitlement.
///
/// Every entitlement is a capability an attacker inherits if the process is
/// compromised, and the two that matter most here are absent by absence:
/// `com.apple.security.get-task-allow` would let another process read the
/// app's memory, where the tokens live, and an App Sandbox key would change
/// where the credential import may read. Asserting the exact key set, rather
/// than asserting the presence of the one we want, is what catches an addition.
final class EntitlementsTests: XCTestCase {
    private let expectedKey = "com.apple.security.network.client"

    func testEntitlementsContainOnlyTheNetworkClientKey() throws {
        let url = RepoAudit.entitlementsFile
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let entitlements = parsed as? [String: Any] else {
            return XCTFail("ISC-132: \(RepoAudit.relativePath(of: url)) is not a plist dictionary")
        }

        XCTAssertEqual(
            entitlements.keys.sorted(),
            [expectedKey],
            RepoAudit.report(
                "ISC-132: unexpected entitlement key set in \(RepoAudit.relativePath(of: url)):",
                entitlements.keys.sorted()
            )
        )
        XCTAssertEqual(
            entitlements[expectedKey] as? Bool,
            true,
            "ISC-132: \(expectedKey) must be <true/>"
        )
    }

    func testProjectEnablesHardenedRuntimeAndPointsAtTheEntitlements() throws {
        let project = RepoAudit.root
            .appendingPathComponent("Throttle.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        let contents = try String(contentsOf: project, encoding: .utf8)

        let entitlementsSettings = contents
            .components(separatedBy: "\n")
            .filter { $0.contains("CODE_SIGN_ENTITLEMENTS") }
        XCTAssertEqual(
            entitlementsSettings.count,
            2,
            "ISC-132: expected CODE_SIGN_ENTITLEMENTS on both app configurations, found \(entitlementsSettings.count)"
        )
        for setting in entitlementsSettings {
            XCTAssertTrue(
                setting.contains("Throttle.entitlements"),
                "ISC-132: CODE_SIGN_ENTITLEMENTS points somewhere unexpected: \(setting.trimmingCharacters(in: .whitespaces))"
            )
        }

        let hardenedRuntimeSettings = contents
            .components(separatedBy: "\n")
            .filter { $0.contains("ENABLE_HARDENED_RUNTIME") }
        XCTAssertEqual(
            hardenedRuntimeSettings.count,
            2,
            "ISC-132: expected ENABLE_HARDENED_RUNTIME on both app configurations, found \(hardenedRuntimeSettings.count)"
        )
        for setting in hardenedRuntimeSettings {
            XCTAssertTrue(
                setting.contains("= YES;"),
                "ISC-132: Hardened Runtime is not YES: \(setting.trimmingCharacters(in: .whitespaces))"
            )
        }
    }
}
