import CryptoKit
import Foundation
import Security

/// What a downloaded package must turn out to be.
struct PackageExpectation: Equatable, Sendable {
    /// The running app's Developer ID team.
    let teamID: String
    /// The release being installed. The package's own Distribution must name
    /// exactly this version, which is also what refuses a downgrade.
    let version: SemanticVersion
    /// The byte count from the release listing.
    let size: Int
    /// The lowercase hex SHA-256 from the release listing, when it had one.
    let sha256: String?
}

/// A package that passed every check, carrying the pins the root step checks
/// again on its own copy: the exact size, the exact bytes, the team, and the
/// version.
struct VerifiedPackage: Equatable, Sendable {
    let url: URL
    let teamID: String
    let version: SemanticVersion
    let size: Int
    /// Lowercase hex SHA-256 of the verified file.
    let sha256: String
}

/// The trust gate every downloaded package passes before anything installs it.
protocol PackageVerifying: Sendable {
    /// The running app's Developer ID team. Throws `UpdateError.unsignedApp`
    /// for an ad-hoc or unsigned build, which has no team to compare against.
    func runningAppTeamID() throws -> String

    /// Throws `UpdateError.verification` unless the package at `url` is
    /// exactly the release it claims to be: the listed size and digest, signed
    /// with a Developer ID Installer certificate from the expected team,
    /// notarized, a Throttle package of exactly the expected version, and free
    /// of install scripts.
    func verify(packageAt url: URL, expecting expected: PackageExpectation) async throws -> VerifiedPackage
}

/// Production verifier: the running app's own code signature for the team;
/// `pkgutil --check-signature` and `spctl --assess --type install` for the
/// signature and notarization; `xar` for the archive's entries and its
/// Distribution; CryptoKit for the bytes.
///
/// Both signature tools are required. `spctl` alone reports a package whose
/// payload was modified after signing as `accepted`; only `pkgutil` checks the
/// archive's checksums and calls it invalid.
struct PackageVerifier: PackageVerifying {
    static let pkgutilPath = "/usr/sbin/pkgutil"
    static let spctlPath = "/usr/sbin/spctl"
    static let xarPath = "/usr/bin/xar"

    /// Apple team identifiers: ten uppercase letters or digits.
    static let teamIDPattern = #"^[A-Z0-9]{10}$"#
    /// A SHA-256 as the updater carries it: 64 lowercase hex digits.
    static let sha256Pattern = #"^[0-9a-f]{64}$"#

    /// The package identifier `scripts/package.sh` gives Throttle's component.
    static let productIdentifier = "ai.parslee.throttle"

    /// The status line `pkgutil` prints for a Developer ID signed package.
    static let developerIDStatus = "Status: signed by a developer certificate issued by Apple for distribution"
    static let installerCertificatePrefix = "Developer ID Installer: "
    static let notarizedSource = "source=Notarized Developer ID"

    /// Largest Distribution read into memory. A real one is about 2 KB.
    static let maxDistributionBytes = 256 * 1024

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

    static func isValidSHA256(_ digest: String) -> Bool {
        WholeMatch.matches(sha256Pattern, digest)
    }

    func runningAppTeamID() throws -> String {
        guard let team = teamIDProvider(), Self.isValidTeamID(team) else {
            throw UpdateError.unsignedApp
        }
        return team
    }

    func verify(packageAt url: URL, expecting expected: PackageExpectation) async throws -> VerifiedPackage {
        guard Self.isValidTeamID(expected.teamID) else { throw UpdateError.unsignedApp }
        guard SemanticVersion.isValid(expected.version.text) else {
            throw UpdateError.verification("the update's version number is not a plain version")
        }
        if let listed = expected.sha256, !Self.isValidSHA256(listed) {
            throw UpdateError.verification("the release's checksum is not a SHA-256")
        }
        try Self.checkRegularFile(at: url, size: expected.size)

        let path = url.path
        let signature: CommandResult
        let assessment: CommandResult
        let listing: CommandResult
        do {
            signature = try await runner.run(Self.pkgutilPath, ["--check-signature", path])
            assessment = try await runner.run(Self.spctlPath, ["--assess", "--type", "install", "-vv", path])
            listing = try await runner.run(Self.xarPath, ["-tf", path])
        } catch {
            throw UpdateError.verification("the package tools could not be run (\(error.localizedDescription))")
        }
        _ = try Self.checkSignature(signature, expectedTeamID: expected.teamID)
        try Self.checkAssessment(assessment)
        try Self.checkArchiveListing(listing)
        try Self.checkDistribution(try await readDistribution(of: url), version: expected.version)

        let digest: String
        do {
            digest = try Self.sha256(of: url)
        } catch {
            throw UpdateError.verification("the package could not be read to check its checksum")
        }
        if let listed = expected.sha256, listed != digest {
            throw UpdateError.verification("the download doesn't match the checksum GitHub published for it")
        }
        return VerifiedPackage(
            url: url,
            teamID: expected.teamID,
            version: expected.version,
            size: expected.size,
            sha256: digest
        )
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

    // MARK: The file itself

    /// A regular file (not a symlink, which `attributesOfItem` does not
    /// follow) of exactly `size` bytes.
    static func checkRegularFile(at url: URL, size: Int) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw UpdateError.verification("the downloaded package could not be found")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw UpdateError.verification("the downloaded package is not a regular file")
        }
        guard (attributes[.size] as? NSNumber)?.intValue == size else {
            throw UpdateError.verification("the download is not the size the release lists")
        }
    }

    /// Lowercase hex SHA-256 of the file, read in 1 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
            if lines.contains(where: { $0.hasPrefix("Status: package is invalid") }) {
                throw UpdateError.verification("the package is damaged or was modified")
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

    /// Accepts `xar -tf` output only for a product archive (it has a
    /// `Distribution`) with no install scripts. Throttle's packages never carry
    /// scripts; another product signed by the same team may.
    static func checkArchiveListing(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw UpdateError.verification("the package's contents could not be read")
        }
        let entries = result.standardOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard entries.contains("Distribution") else {
            throw UpdateError.verification("this package isn't a Throttle installer")
        }
        if entries.contains(where: { $0.hasSuffix("Scripts") }) {
            throw UpdateError.verification("the package contains install scripts, which Throttle's packages never do")
        }
    }

    /// Accepts a Distribution only when every `pkg-ref` names Throttle and
    /// exactly one carries a version, which is `version`. Attribute order and
    /// any extra attributes `productbuild` adds do not matter.
    static func checkDistribution(_ xml: Data, version: SemanticVersion) throws {
        let collector = PackageReferenceCollector()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), !collector.references.isEmpty else {
            throw UpdateError.verification("the package's Distribution could not be read")
        }
        guard collector.references.allSatisfy({ $0["id"] == productIdentifier }) else {
            throw UpdateError.verification("this package isn't Throttle")
        }
        let versions = collector.references.compactMap { $0["version"] }
        guard versions == [version.text] else {
            throw UpdateError.verification("this package isn't Throttle \(version.text)")
        }
    }

    /// Extracts the archive's `Distribution` into a private temporary
    /// directory with `xar` and reads it back, capped in size.
    private func readDistribution(of url: URL) async throws -> Data {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("throttle-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateError.verification("Throttle couldn't make a folder to inspect the package")
        }
        defer { try? fm.removeItem(at: directory) }

        let result: CommandResult
        do {
            result = try await runner.run(Self.xarPath, ["-xf", url.path, "-C", directory.path, "Distribution"])
        } catch {
            throw UpdateError.verification("the package tools could not be run (\(error.localizedDescription))")
        }
        let file = directory.appendingPathComponent("Distribution", isDirectory: false)
        guard result.status == 0,
              let attributes = try? fm.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= Self.maxDistributionBytes,
              let data = fm.contents(atPath: file.path) else {
            throw UpdateError.verification("the package's Distribution could not be read")
        }
        return data
    }

    /// `Developer ID Installer: Example Corp (ABCDE12345)` -> `ABCDE12345`.
    /// Only a final ` (TEAMID)` counts, so an organization name that itself
    /// contains parentheses cannot supply the team.
    static func trailingTeamID(_ commonName: String) -> String? {
        guard commonName.hasSuffix(")"), let open = commonName.lastIndex(of: "("),
              open > commonName.startIndex,
              commonName[commonName.index(before: open)] == " " else { return nil }
        let inner = String(commonName[commonName.index(after: open)..<commonName.index(before: commonName.endIndex)])
        return isValidTeamID(inner) ? inner : nil
    }
}

/// Collects the attributes of every `pkg-ref` element in a Distribution.
private final class PackageReferenceCollector: NSObject, XMLParserDelegate {
    var references: [[String: String]] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if elementName == "pkg-ref" {
            references.append(attributes)
        }
    }
}
