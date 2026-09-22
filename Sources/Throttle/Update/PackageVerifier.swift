import Foundation
import Security

/// The trust gate every downloaded package passes before anything installs it.
protocol PackageVerifying: Sendable {
    /// The running app's Developer ID team. Throws `UpdateError.unsignedApp`
    /// for an ad-hoc or unsigned build, which has no team to compare against.
    func runningAppTeamID() throws -> String

    /// Throws `UpdateError.verification` unless the package at `url` is signed
    /// with a Developer ID Installer certificate from `teamID` and Gatekeeper
    /// accepts it as notarized.
    func verify(packageAt url: URL, teamID: String) async throws
}

/// Production verifier: the running app's own code signature for the team,
/// then `pkgutil --check-signature` and `spctl --assess --type install` on the
/// package. Both tools run through `CommandRunning` with an argument vector.
struct PackageVerifier: PackageVerifying {
    static let pkgutilPath = "/usr/sbin/pkgutil"
    static let spctlPath = "/usr/sbin/spctl"

    /// Apple team identifiers: ten uppercase letters or digits.
    static let teamIDPattern = #"^[A-Z0-9]{10}$"#

    /// The status line `pkgutil` prints for a Developer ID signed package.
    static let developerIDStatus = "Status: signed by a developer certificate issued by Apple for distribution"
    static let installerCertificatePrefix = "Developer ID Installer: "
    static let notarizedSource = "source=Notarized Developer ID"

    let runner: any CommandRunning
    /// Where the running app's team comes from. Injectable so tests can stand
    /// in for a Developer ID build or an ad-hoc one.
    let teamIDProvider: @Sendable () -> String?

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        teamIDProvider: @escaping @Sendable () -> String? = { PackageVerifier.currentProcessTeamID() }
    ) {
        self.runner = runner
        self.teamIDProvider = teamIDProvider
    }

    static func isValidTeamID(_ teamID: String) -> Bool {
        WholeMatch.matches(teamIDPattern, teamID)
    }

    func runningAppTeamID() throws -> String {
        guard let team = teamIDProvider(), Self.isValidTeamID(team) else {
            throw UpdateError.unsignedApp
        }
        return team
    }

    func verify(packageAt url: URL, teamID: String) async throws {
        guard Self.isValidTeamID(teamID) else { throw UpdateError.unsignedApp }
        let path = url.path

        let signature: CommandResult
        let assessment: CommandResult
        do {
            signature = try await runner.run(Self.pkgutilPath, ["--check-signature", path])
            assessment = try await runner.run(Self.spctlPath, ["--assess", "--type", "install", "-vv", path])
        } catch {
            throw UpdateError.verification("the signature tools could not be run (\(error.localizedDescription))")
        }
        _ = try Self.checkSignature(signature, expectedTeamID: teamID)
        try Self.checkAssessment(assessment)
    }

    // MARK: The running app's team

    /// Reads `kSecCodeInfoTeamIdentifier` from this process's own static code.
    /// `nil` for an ad-hoc or unsigned build, and for anything that is not a
    /// well-formed team identifier.
    static func currentProcessTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              isValidTeamID(team) else {
            return nil
        }
        return team
    }

    // MARK: Parsing tool output

    /// What `pkgutil --check-signature` said about a package.
    struct Signature: Equatable, Sendable {
        /// The leaf certificate's common name, e.g.
        /// `Developer ID Installer: Example Corp (ABCDE12345)`.
        let leafCommonName: String
        let teamID: String
        /// Whether `pkgutil` also reported a notarization ticket. Informational:
        /// `spctl` is what enforces notarization.
        let notarized: Bool
    }

    /// Accepts `pkgutil --check-signature` output only when it exited 0, its
    /// status line is the Developer ID one, and certificate 1 of the chain is a
    /// Developer ID Installer certificate whose team is `expectedTeamID`.
    static func checkSignature(_ result: CommandResult, expectedTeamID: String) throws -> Signature {
        let lines = result.combinedOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard result.status == 0 else {
            if lines.contains(where: { $0.hasPrefix("Status: no signature") }) {
                throw UpdateError.verification("the package is not signed")
            }
            throw UpdateError.verification("pkgutil could not check the package's signature")
        }
        guard lines.contains(developerIDStatus) else {
            throw UpdateError.verification("the package is not signed with a Developer ID certificate")
        }
        guard let chainStart = lines.firstIndex(of: "Certificate Chain:"),
              let leafLine = lines[chainStart...].first(where: { $0.hasPrefix("1. ") }) else {
            throw UpdateError.verification("pkgutil did not report a certificate chain")
        }
        let leaf = String(leafLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard leaf.hasPrefix(installerCertificatePrefix) else {
            throw UpdateError.verification("the package is not signed with a Developer ID Installer certificate")
        }
        guard let team = trailingTeamID(leaf) else {
            throw UpdateError.verification("the package's certificate names no developer team")
        }
        guard team == expectedTeamID else {
            throw UpdateError.verification("the package is signed by a different developer than this copy of Throttle")
        }
        let notarized = lines.contains { $0.hasPrefix("Notarization: trusted by the Apple notary service") }
        return Signature(leafCommonName: leaf, teamID: team, notarized: notarized)
    }

    /// Accepts `spctl --assess --type install -vv` output only when it exited 0,
    /// reported the package `accepted`, and named a notarized Developer ID
    /// source.
    static func checkAssessment(_ result: CommandResult) throws {
        let lines = result.combinedOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let accepted = lines.contains { $0.hasSuffix(": accepted") }
        guard result.status == 0, accepted else {
            throw UpdateError.verification("macOS Gatekeeper rejected the package")
        }
        guard lines.contains(notarizedSource) else {
            throw UpdateError.verification("the package is not notarized by Apple")
        }
    }

    /// `Developer ID Installer: Example Corp (ABCDE12345)` -> `ABCDE12345`.
    /// Only the final parenthesized group counts, so an organization name that
    /// itself contains parentheses cannot supply the team.
    static func trailingTeamID(_ commonName: String) -> String? {
        guard commonName.hasSuffix(")"), let open = commonName.lastIndex(of: "(") else { return nil }
        let inner = String(commonName[commonName.index(after: open)..<commonName.index(before: commonName.endIndex)])
        return isValidTeamID(inner) ? inner : nil
    }
}
