import XCTest
@testable import Throttle

final class PackageVerifierTests: XCTestCase {
    private let team = UpdateFixtures.team

    private func assertRejected(
        _ result: CommandResult,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PackageVerifier.checkSignature(result, expectedTeamID: team), file: file, line: line) { error in
            guard case UpdateError.verification(let reason)? = error as? UpdateError else {
                return XCTFail("expected verification error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(fragment), "\(reason) should mention \(fragment)", file: file, line: line)
        }
    }

    // MARK: pkgutil

    func testAcceptsADeveloperIDInstallerSignatureFromTheSameTeam() throws {
        let signature = try PackageVerifier.checkSignature(UpdateFixtures.pkgutilSigned(), expectedTeamID: team)
        XCTAssertEqual(signature.teamID, "ABCDE12345")
        XCTAssertEqual(signature.leafCommonName, "Developer ID Installer: Example Corp (ABCDE12345)")
        XCTAssertTrue(signature.notarized)
    }

    func testANotarizationLineIsInformationalOnly() throws {
        let signature = try PackageVerifier.checkSignature(UpdateFixtures.pkgutilSigned(notarized: false), expectedTeamID: team)
        XCTAssertFalse(signature.notarized)
    }

    func testRejectsAnotherTeam() {
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Other Corp (\(UpdateFixtures.otherTeam))"),
            containing: "different developer"
        )
    }

    func testRejectsACertificateThatIsNotDeveloperIDInstaller() {
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Application: Example Corp (ABCDE12345)"),
            containing: "Developer ID Installer"
        )
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "3rd Party Mac Developer Installer: Example Corp (ABCDE12345)"),
            containing: "Developer ID Installer"
        )
    }

    func testRejectsAnUnsignedPackage() {
        assertRejected(UpdateFixtures.pkgutilUnsigned, containing: "not signed")
    }

    func testRejectsAStatusOtherThanDeveloperID() {
        assertRejected(UpdateFixtures.pkgutilSigned(status: "signed Apple Software"), containing: "Developer ID")
        assertRejected(
            UpdateFixtures.pkgutilSigned(status: "signed by a certificate trusted by Mac OS X"),
            containing: "Developer ID"
        )
    }

    func testRejectsANonzeroExitEvenWithGoodLookingOutput() {
        let signed = UpdateFixtures.pkgutilSigned()
        let failed = CommandResult(status: 1, standardOutput: signed.standardOutput, standardError: "")
        assertRejected(failed, containing: "pkgutil")
    }

    func testTheTeamIsTheFinalParenthesizedGroup() throws {
        let signature = try PackageVerifier.checkSignature(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Example (ZYXWV98765) Corp (ABCDE12345)"),
            expectedTeamID: team
        )
        XCTAssertEqual(signature.teamID, "ABCDE12345")
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Example Corp (ABCDE12345) (abcde12345)"),
            containing: "no developer team"
        )
    }

    // MARK: spctl

    func testAcceptsANotarizedAssessment() throws {
        XCTAssertNoThrow(try PackageVerifier.checkAssessment(UpdateFixtures.spctlAccepted()))
    }

    func testRejectsARejectedAssessment() {
        XCTAssertThrowsError(try PackageVerifier.checkAssessment(UpdateFixtures.spctlRejected))
    }

    func testRejectsAnAcceptedButUnnotarizedAssessment() {
        XCTAssertThrowsError(try PackageVerifier.checkAssessment(UpdateFixtures.spctlAccepted(source: "Developer ID"))) { error in
            XCTAssertEqual(error as? UpdateError, .verification("the package is not notarized by Apple"))
        }
    }

    func testRejectsAZeroExitWithoutAnAcceptedVerdict() {
        let odd = CommandResult(status: 0, standardOutput: "", standardError: "source=Notarized Developer ID\n")
        XCTAssertThrowsError(try PackageVerifier.checkAssessment(odd))
    }

    // MARK: The running app

    func testAnAdHocAppIsRefused() {
        let verifier = PackageVerifier(runner: ScriptedCommandRunner([:]), teamIDProvider: { nil })
        XCTAssertThrowsError(try verifier.runningAppTeamID()) { error in
            XCTAssertEqual(error as? UpdateError, .unsignedApp)
            XCTAssertEqual(
                (error as? UpdateError)?.userMessage,
                "This copy of Throttle isn't signed with a Developer ID, so it can't verify an update. Download the new version from GitHub."
            )
        }
    }

    func testMalformedTeamIDsAreRefused() {
        for bad in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE12345\n", "ABCDE 2345", "not set"] {
            let verifier = PackageVerifier(runner: ScriptedCommandRunner([:]), teamIDProvider: { bad })
            XCTAssertThrowsError(try verifier.runningAppTeamID(), bad.debugDescription)
        }
        let good = PackageVerifier(runner: ScriptedCommandRunner([:]), teamIDProvider: { "ABCDE12345" })
        XCTAssertEqual(try good.runningAppTeamID(), "ABCDE12345")
    }

    /// The test host is built ad-hoc; the real lookup must say so rather than
    /// crash or invent a team.
    func testTheRealLookupReturnsNothingOrAWellFormedTeam() {
        if let team = PackageVerifier.currentProcessTeamID() {
            XCTAssertTrue(PackageVerifier.isValidTeamID(team))
        }
    }

    // MARK: verify()

    func testVerifyRunsBothToolsWithAnArgumentVector() async throws {
        let runner = ScriptedCommandRunner([
            PackageVerifier.pkgutilPath: [UpdateFixtures.pkgutilSigned()],
            PackageVerifier.spctlPath: [UpdateFixtures.spctlAccepted()],
        ])
        let verifier = PackageVerifier(runner: runner, teamIDProvider: { nil })
        let hostile = URL(fileURLWithPath: "/tmp/it's a \"pkg\" $(id) `id`.pkg")
        try await verifier.verify(packageAt: hostile, teamID: team)

        let calls = runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executable, "/usr/sbin/pkgutil")
        XCTAssertEqual(calls[0].arguments, ["--check-signature", hostile.path])
        XCTAssertEqual(calls[1].executable, "/usr/sbin/spctl")
        XCTAssertEqual(calls[1].arguments, ["--assess", "--type", "install", "-vv", hostile.path])
    }

    func testVerifyFailsOnAGatekeeperRejection() async {
        let runner = ScriptedCommandRunner([
            PackageVerifier.pkgutilPath: [UpdateFixtures.pkgutilSigned()],
            PackageVerifier.spctlPath: [UpdateFixtures.spctlRejected],
        ])
        let verifier = PackageVerifier(runner: runner, teamIDProvider: { nil })
        do {
            try await verifier.verify(packageAt: URL(fileURLWithPath: UpdateFixtures.packagePath), teamID: team)
            XCTFail("expected a rejection")
        } catch {
            guard case UpdateError.verification? = error as? UpdateError else { return XCTFail("got \(error)") }
        }
    }
}
