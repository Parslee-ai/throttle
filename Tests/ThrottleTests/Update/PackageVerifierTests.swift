import XCTest
@testable import Throttle

final class PackageVerifierTests: XCTestCase {
    private let team = UpdateFixtures.team
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try UpdateFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

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

    func testAnInvalidPackageReadsAsDamaged() {
        assertRejected(UpdateFixtures.pkgutilInvalid, containing: "the package is damaged or was modified")
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

    func testTheTeamIsOnlyAFinalSpaceParenthesizedGroup() throws {
        let signature = try PackageVerifier.checkSignature(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Example (ZYXWV98765) Corp (ABCDE12345)"),
            expectedTeamID: team
        )
        XCTAssertEqual(signature.teamID, "ABCDE12345")
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Example Corp (ABCDE12345) (abcde12345)"),
            containing: "no developer team"
        )
        XCTAssertNil(PackageVerifier.trailingTeamID("Developer ID Installer: Example(ABCDE12345)"))
    }

    /// The red team's crafted leaves: the expected team placed somewhere other
    /// than the end.
    func testCraftedLeavesCarryingTheTeamElsewhereAreRejected() {
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Evil (ABCDE12345) Corp (EVILTEAM01)"),
            containing: "different developer"
        )
        assertRejected(
            UpdateFixtures.pkgutilSigned(leaf: "Developer ID Installer: Evil (EVILTEAM01) (ABCDE12345)x"),
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

    // MARK: Archive and Distribution

    func testAThrottleListingIsAccepted() {
        XCTAssertNoThrow(try PackageVerifier.checkArchiveListing(UpdateFixtures.xarListing()))
    }

    func testAListingWithScriptsIsRejected() {
        XCTAssertThrowsError(try PackageVerifier.checkArchiveListing(UpdateFixtures.xarListing(scripts: true))) { error in
            XCTAssertEqual(error as? UpdateError, .verification("the package contains install scripts, which Throttle's packages never do"))
        }
        let topLevel = CommandResult(status: 0, standardOutput: "Scripts\nDistribution\n", standardError: "")
        XCTAssertThrowsError(try PackageVerifier.checkArchiveListing(topLevel))
    }

    func testAListingWithoutADistributionIsRejected() {
        let component = CommandResult(status: 0, standardOutput: "Bom\nPayload\nPackageInfo\n", standardError: "")
        XCTAssertThrowsError(try PackageVerifier.checkArchiveListing(component))
        XCTAssertThrowsError(try PackageVerifier.checkArchiveListing(CommandResult(status: 1, standardOutput: "", standardError: "")))
    }

    func testTheRealDistributionShapeIsAccepted() {
        let xml = Data(UpdateFixtures.distribution(version: "0.2.0").utf8)
        XCTAssertNoThrow(try PackageVerifier.checkDistribution(xml, version: SemanticVersion("0.2.0")!))
    }

    func testDistributionAttributeOrderDoesNotMatter() {
        let xml = Data("""
        <?xml version="1.0"?>
        <installer-gui-script minSpecVersion="2">
            <pkg-ref installKBytes="1" version="0.2.0" onConclusion="none" id="ai.parslee.throttle">#a.pkg</pkg-ref>
            <pkg-ref id="ai.parslee.throttle"/>
        </installer-gui-script>
        """.utf8)
        XCTAssertNoThrow(try PackageVerifier.checkDistribution(xml, version: SemanticVersion("0.2.0")!))
    }

    func testAnotherProductIsRejected() {
        let other = Data(UpdateFixtures.distribution(id: "com.example.other-app").utf8)
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(other, version: SemanticVersion("0.2.0")!)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("this package isn't Throttle"))
        }
        let bundled = Data(UpdateFixtures.distribution(extraReference: "com.example.helper").utf8)
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(bundled, version: SemanticVersion("0.2.0")!)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("this package isn't Throttle"))
        }
    }

    func testAnotherVersionIsRejectedIncludingADowngrade() {
        let candidate = Data(UpdateFixtures.distribution(version: "0.1.0-rc.1").utf8)
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(candidate, version: SemanticVersion("0.1.0")!)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("this package isn't Throttle 0.1.0"))
        }
        let newer = Data(UpdateFixtures.distribution(version: "0.3.0").utf8)
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(newer, version: SemanticVersion("0.2.0")!))
    }

    func testAnUnreadableDistributionIsRejected() {
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(Data("<installer-gui-script><pkg-ref".utf8), version: SemanticVersion("0.2.0")!))
        XCTAssertThrowsError(try PackageVerifier.checkDistribution(Data("<installer-gui-script/>".utf8), version: SemanticVersion("0.2.0")!))
    }

    // MARK: The file and its bytes

    func testTheDigestIsComputedFromTheFile() throws {
        let file = directory.appendingPathComponent("abc.pkg")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try PackageVerifier.sha256(of: file), UpdateFixtures.abcSHA256)
    }

    func testASymlinkIsNotARegularFile() throws {
        let target = directory.appendingPathComponent("real.pkg")
        try Data("abc".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PackageVerifier.checkRegularFile(at: link, size: 3)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("the downloaded package is not a regular file"))
        }
        XCTAssertNoThrow(try PackageVerifier.checkRegularFile(at: target, size: 3))
    }

    func testTheWrongSizeIsRejected() throws {
        let file = directory.appendingPathComponent("abc.pkg")
        try Data("abcd".utf8).write(to: file)
        XCTAssertThrowsError(try PackageVerifier.checkRegularFile(at: file, size: 3)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("the download is not the size the release lists"))
        }
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

    /// A three-byte stand-in package whose tool output is scripted.
    private func stage(
        pkgutil: CommandResult = UpdateFixtures.pkgutilSigned(),
        spctl: CommandResult = UpdateFixtures.spctlAccepted(),
        listing: CommandResult = UpdateFixtures.xarListing(),
        distribution: String? = UpdateFixtures.distribution(version: "0.2.0"),
        name: String = "Throttle-0.2.0.pkg"
    ) throws -> (URL, ScriptedCommandRunner) {
        let file = directory.appendingPathComponent(name)
        try Data("abc".utf8).write(to: file)
        let runner = ScriptedCommandRunner([
            PackageVerifier.pkgutilPath: [pkgutil],
            PackageVerifier.spctlPath: [spctl],
            PackageVerifier.xarPath: [listing],
        ], extractedDistribution: distribution)
        return (file, runner)
    }

    private func expectation(version: String = "0.2.0", size: Int = 3, sha256: String? = UpdateFixtures.abcSHA256) -> PackageExpectation {
        PackageExpectation(teamID: team, version: SemanticVersion(version)!, size: size, sha256: sha256)
    }

    private func verifyError(
        _ file: URL,
        _ runner: ScriptedCommandRunner,
        _ expected: PackageExpectation
    ) async -> UpdateError? {
        do {
            _ = try await PackageVerifier(runner: runner, teamIDProvider: { nil }).verify(packageAt: file, expecting: expected)
            return nil
        } catch {
            return error as? UpdateError
        }
    }

    func testVerifyAcceptsTheExpectedPackageAndPinsItsBytes() async throws {
        let (file, runner) = try stage(name: "it's a \"pkg\" $(id) `id`.pkg")
        let verified = try await PackageVerifier(runner: runner, teamIDProvider: { nil })
            .verify(packageAt: file, expecting: expectation())

        XCTAssertEqual(verified, VerifiedPackage(
            url: file, teamID: team, version: SemanticVersion("0.2.0")!, size: 3, sha256: UpdateFixtures.abcSHA256
        ))
        let calls = runner.calls
        XCTAssertEqual(calls.map(\.executable), ["/usr/sbin/pkgutil", "/usr/sbin/spctl", "/usr/bin/xar", "/usr/bin/xar"])
        XCTAssertEqual(calls[0].arguments, ["--check-signature", file.path])
        XCTAssertEqual(calls[1].arguments, ["--assess", "--type", "install", "-vv", file.path])
        XCTAssertEqual(calls[2].arguments, ["-tf", file.path])
        XCTAssertEqual(Array(calls[3].arguments.prefix(3)), ["-xf", file.path, "-C"])
        XCTAssertEqual(calls[3].arguments.last, "Distribution")
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls[3].arguments[3]), "the scratch folder is removed")
    }

    func testVerifyWithoutAListedDigestStillPinsTheComputedOne() async throws {
        let (file, runner) = try stage()
        let verified = try await PackageVerifier(runner: runner, teamIDProvider: { nil })
            .verify(packageAt: file, expecting: expectation(sha256: nil))
        XCTAssertEqual(verified.sha256, UpdateFixtures.abcSHA256)
    }

    func testVerifyRefusesAHashMismatch() async throws {
        let (file, runner) = try stage()
        let error = await verifyError(file, runner, expectation(sha256: UpdateFixtures.zeroSHA256))
        XCTAssertEqual(error, .verification("the download doesn't match the checksum GitHub published for it"))
    }

    func testVerifyRefusesABadDigestFormat() async throws {
        let (file, runner) = try stage()
        for bad in [UpdateFixtures.abcSHA256.uppercased(), "sha256:" + UpdateFixtures.abcSHA256, "abc"] {
            let error = await verifyError(file, runner, expectation(sha256: bad))
            XCTAssertEqual(error, .verification("the release's checksum is not a SHA-256"), bad)
        }
        XCTAssertEqual(runner.calls.count, 0, "refused before any tool runs")
    }

    func testVerifyRefusesAnotherProduct() async throws {
        let (file, runner) = try stage(distribution: UpdateFixtures.distribution(id: "com.example.other-app"))
        let error = await verifyError(file, runner, expectation())
        XCTAssertEqual(error, .verification("this package isn't Throttle"))
        XCTAssertTrue(error!.userMessage.contains("this package isn't Throttle"))
    }

    func testVerifyRefusesADowngrade() async throws {
        let (file, runner) = try stage(distribution: UpdateFixtures.distribution(version: "0.1.0-rc.1"))
        let error = await verifyError(file, runner, expectation(version: "0.1.0"))
        XCTAssertEqual(error, .verification("this package isn't Throttle 0.1.0"))
    }

    func testVerifyRefusesScripts() async throws {
        let (file, runner) = try stage(listing: UpdateFixtures.xarListing(scripts: true))
        let error = await verifyError(file, runner, expectation())
        XCTAssertEqual(error, .verification("the package contains install scripts, which Throttle's packages never do"))
    }

    func testVerifyRefusesASymlinkedDownload() async throws {
        let (file, runner) = try stage()
        let link = directory.appendingPathComponent("Throttle-link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let error = await verifyError(link, runner, expectation())
        XCTAssertEqual(error, .verification("the downloaded package is not a regular file"))
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testVerifyRefusesTheWrongSize() async throws {
        let (file, runner) = try stage()
        let error = await verifyError(file, runner, expectation(size: 4))
        XCTAssertEqual(error, .verification("the download is not the size the release lists"))
    }

    func testVerifyFailsOnAGatekeeperRejection() async throws {
        let (file, runner) = try stage(spctl: UpdateFixtures.spctlRejected)
        let error = await verifyError(file, runner, expectation())
        XCTAssertEqual(error, .verification("macOS Gatekeeper rejected the package"))
    }
}
