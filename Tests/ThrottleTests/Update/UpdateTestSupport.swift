import Foundation
import XCTest
@testable import Throttle

/// Canned tool output and release listings for the updater tests. The shapes
/// are copied from real `pkgutil --check-signature`, `spctl --assess`, and
/// `xar` output and from a real `productbuild` Distribution; the organization,
/// team, and digests are fictional.
enum UpdateFixtures {
    static let team = "ABCDE12345"
    static let otherTeam = "ZYXWV98765"
    static let packagePath = "/Users/example/Library/Caches/ai.parslee.throttle/Updates/Throttle-0.2.0.pkg"
    /// SHA-256 of the three bytes `abc`.
    static let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let zeroSHA256 = String(repeating: "0", count: 64)

    static func pkgutilSigned(
        leaf: String = "Developer ID Installer: Example Corp (ABCDE12345)",
        status: String = "signed by a developer certificate issued by Apple for distribution",
        notarized: Bool = true
    ) -> CommandResult {
        var lines = [
            #"Package "Throttle-0.2.0.pkg":"#,
            "   Status: \(status)",
        ]
        if notarized {
            lines.append("   Notarization: trusted by the Apple notary service")
        }
        lines += [
            "   Signed with a trusted timestamp on: 2026-01-01 00:00:00 +0000",
            "   Certificate Chain:",
            "    1. \(leaf)",
            "       Expires: 2031-01-01 00:00:00 +0000",
            "       SHA256 Fingerprint:",
            "           00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF 00 11 22 33 44 55 ",
            "           66 77 88 99 AA BB CC DD EE FF",
            "       ------------------------------------------------------------------------",
            "    2. Developer ID Certification Authority",
            "       Expires: 2031-01-01 00:00:00 +0000",
            "       SHA256 Fingerprint:",
            "           FF EE DD CC BB AA 99 88 77 66 55 44 33 22 11 00 FF EE DD CC BB AA ",
            "           99 88 77 66 55 44 33 22 11 00",
            "       ------------------------------------------------------------------------",
            "    3. Apple Root CA",
            "       Expires: 2035-01-01 00:00:00 +0000",
            "       SHA256 Fingerprint:",
            "           12 34 56 78 9A BC DE F0 12 34 56 78 9A BC DE F0 12 34 56 78 9A BC ",
            "           DE F0 12 34 56 78 9A BC DE F0",
            "",
        ]
        return CommandResult(status: 0, standardOutput: lines.joined(separator: "\n"), standardError: "")
    }

    static let pkgutilUnsigned = CommandResult(
        status: 1,
        standardOutput: "Package \"Throttle-0.2.0.pkg\":\n   Status: no signature\n",
        standardError: ""
    )

    /// What `pkgutil` says about a signed package whose payload was modified.
    static let pkgutilInvalid = CommandResult(
        status: 1,
        standardOutput: "Package \"Throttle-0.2.0.pkg\":\n   Status: package is invalid (checksum did not verify)\n",
        standardError: ""
    )

    /// `spctl` writes its verdict to stderr.
    static func spctlAccepted(source: String = "Notarized Developer ID") -> CommandResult {
        CommandResult(
            status: 0,
            standardOutput: "",
            standardError: "\(packagePath): accepted\nsource=\(source)\norigin=Developer ID Installer: Example Corp (ABCDE12345)\n"
        )
    }

    static let spctlRejected = CommandResult(
        status: 3,
        standardOutput: "",
        standardError: "\(packagePath): rejected\nsource=no usable signature\n"
    )

    /// `xar -tf` of a Throttle product archive, optionally with the `Scripts`
    /// entry another product's component carries.
    static func xarListing(component: String = ".throttle-app.pkg", scripts: Bool = false) -> CommandResult {
        var entries = ["\(component)", "\(component)/Bom", "\(component)/Payload"]
        if scripts { entries.append("\(component)/Scripts") }
        entries += ["\(component)/PackageInfo", "Distribution", ""]
        return CommandResult(status: 0, standardOutput: entries.joined(separator: "\n"), standardError: "")
    }

    /// A Distribution in `productbuild`'s shape, as `scripts/package.sh` makes
    /// it. `extraReference` adds another product's versioned `pkg-ref`.
    static func distribution(
        id: String = "ai.parslee.throttle",
        version: String = "0.2.0",
        extraReference: String? = nil
    ) -> String {
        var refs = """
            <choice id="default"/>
            <choice id="\(id)" visible="false">
                <pkg-ref id="\(id)"/>
            </choice>
            <pkg-ref id="\(id)" version="\(version)" onConclusion="none" installKBytes="4630" updateKBytes="0">#.throttle-app.pkg</pkg-ref>
            <pkg-ref id="\(id)">
                <bundle-version>
                    <bundle CFBundleShortVersionString="\(version)" CFBundleVersion="1" id="\(id)" path="Throttle.app"/>
                </bundle-version>
            </pkg-ref>
        """
        if let extraReference {
            refs += "\n    <pkg-ref id=\"\(extraReference)\" version=\"\(version)\" onConclusion=\"none\">#.other.pkg</pkg-ref>"
        }
        return """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <installer-gui-script minSpecVersion="2">
            <title>Throttle</title>
            <organization>ai.parslee</organization>
            <domains enable_localSystem="true"/>
            <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
            <choices-outline>
                <line choice="default">
                    <line choice="\(id)"/>
                </line>
            </choices-outline>
        \(refs)
            <product version="\(version)"/>
        </installer-gui-script>
        """
    }

    /// A release listing in GitHub's shape with only the fields that matter.
    /// `digest` of `.some(nil)` writes an explicit JSON null.
    static func releaseJSON(
        tag: String = "v0.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = nil,
        downloadURL: String? = nil,
        size: Int = 1_339_213,
        digest: String?? = .some("sha256:" + zeroSHA256)
    ) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = assetName ?? "Throttle-\(version).pkg"
        let url = downloadURL ?? "https://github.com/Parslee-ai/throttle/releases/download/\(tag)/\(name)"
        var asset: [String: Any] = ["name": name, "browser_download_url": url, "size": size]
        switch digest {
        case .none: break
        case .some(.none): asset["digest"] = NSNull()
        case .some(.some(let value)): asset["digest"] = value
        }
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": [asset],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    static func release(_ version: String, size: Int = 64, sha256: String? = zeroSHA256) -> AvailableRelease {
        let v = SemanticVersion(version)!
        return AvailableRelease(
            version: v,
            asset: ReleaseAsset(
                name: "Throttle-\(version).pkg",
                downloadURL: ReleaseFeed.expectedDownloadURL(for: v)!,
                size: size,
                sha256: sha256
            )
        )
    }

    static func verified(
        path: String = packagePath,
        version: String = "0.2.0",
        size: Int = 1_339_213,
        sha256: String = zeroSHA256
    ) -> VerifiedPackage {
        VerifiedPackage(
            url: URL(fileURLWithPath: path),
            teamID: team,
            version: SemanticVersion(version)!,
            size: size,
            sha256: sha256
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Returns scripted results per executable and records every invocation.
/// Never launches anything. When `extractedDistribution` is set, an
/// `xar -xf ... -C <dir> Distribution` call writes it into `<dir>` the way the
/// real tool would.
final class ScriptedCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: [CommandResult]]
    private var invocations: [(executable: String, arguments: [String])] = []
    var extractedDistribution: String?

    init(_ scripted: [String: [CommandResult]], extractedDistribution: String? = nil) {
        self.scripted = scripted
        self.extractedDistribution = extractedDistribution
    }

    var calls: [(executable: String, arguments: [String])] { lock.withLock { invocations } }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        if arguments.first == "-xf", let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count {
            lock.withLock { invocations.append((executable, arguments)) }
            guard let extractedDistribution else {
                return CommandResult(status: 1, standardOutput: "", standardError: "mock: no Distribution")
            }
            let file = URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("Distribution")
            try Data(extractedDistribution.utf8).write(to: file)
            return CommandResult(status: 0, standardOutput: "", standardError: "")
        }
        return try lock.withLock {
            invocations.append((executable, arguments))
            guard var queue = scripted[executable], !queue.isEmpty else {
                throw UpdateError.install("mock: nothing scripted for \(executable)")
            }
            let next = queue.removeFirst()
            scripted[executable] = queue
            return next
        }
    }
}

/// Writes a small file where the real downloader would put the package.
final class MockDownloader: PackageDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [ReleaseAsset] = []
    private var files: [URL] = []
    var error: UpdateError?

    var count: Int { lock.withLock { downloads.count } }
    var writtenFiles: [URL] { lock.withLock { files } }

    func download(_ asset: ReleaseAsset, into directory: URL) async throws -> URL {
        lock.withLock { downloads.append(asset) }
        if let error { throw error }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(asset.name)
        try Data(repeating: 0x2A, count: asset.size).write(to: file)
        lock.withLock { files.append(file) }
        return file
    }
}

final class MockVerifier: PackageVerifying, @unchecked Sendable {
    private let lock = NSLock()
    var teamID: String? = UpdateFixtures.team
    var verifyError: UpdateError?
    private var verified: [(URL, PackageExpectation)] = []

    var verifications: [(URL, PackageExpectation)] { lock.withLock { verified } }

    func runningAppTeamID() throws -> String {
        guard let teamID else { throw UpdateError.unsignedApp }
        return teamID
    }

    func verify(packageAt url: URL, expecting expected: PackageExpectation) async throws -> VerifiedPackage {
        lock.withLock { verified.append((url, expected)) }
        if let verifyError { throw verifyError }
        return VerifiedPackage(
            url: url,
            teamID: expected.teamID,
            version: expected.version,
            size: expected.size,
            sha256: expected.sha256 ?? UpdateFixtures.abcSHA256
        )
    }
}

final class MockInstaller: UpdateInstalling, @unchecked Sendable {
    enum Outcome {
        case success
        case cancel
        /// The root step refused its copy (exit 65).
        case refuse(String)
        case fail(String)
    }

    private let lock = NSLock()
    var outcomes: [Outcome] = [.success]
    var relaunchError: UpdateError?
    private var installed: [VerifiedPackage] = []
    private var relaunched = 0

    var installs: [VerifiedPackage] { lock.withLock { installed } }
    var relaunchCount: Int { lock.withLock { relaunched } }

    func install(_ package: VerifiedPackage) async throws {
        let outcome = lock.withLock { () -> Outcome in
            installed.append(package)
            return outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .success)
        }
        switch outcome {
        case .success: return
        case .cancel: throw InstallCancelled()
        case .refuse(let reason): throw UpdateError.verification(reason)
        case .fail(let message): throw UpdateError.install(message)
        }
    }

    @MainActor
    func relaunch() throws {
        lock.withLock { relaunched += 1 }
        if let relaunchError { throw relaunchError }
    }
}
