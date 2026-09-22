import Foundation
import XCTest
@testable import Throttle

/// Canned tool output and release listings for the updater tests. The shapes
/// are copied from real `pkgutil --check-signature` and `spctl --assess`
/// output; the organization and team are fictional.
enum UpdateFixtures {
    static let team = "ABCDE12345"
    static let otherTeam = "ZYXWV98765"
    static let packagePath = "/Users/example/Library/Caches/ai.parslee.throttle/Updates/Throttle-0.2.0.pkg"

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

    /// A release listing in GitHub's shape with only the fields that matter.
    static func releaseJSON(
        tag: String = "v0.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = nil,
        downloadURL: String? = nil,
        size: Int = 1_339_213
    ) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = assetName ?? "Throttle-\(version).pkg"
        let url = downloadURL ?? "https://github.com/Parslee-ai/throttle/releases/download/\(tag)/\(name)"
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": [["name": name, "browser_download_url": url, "size": size]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    static func release(_ version: String, size: Int = 64) -> AvailableRelease {
        let v = SemanticVersion(version)!
        return AvailableRelease(
            version: v,
            asset: ReleaseAsset(
                name: "Throttle-\(version).pkg",
                downloadURL: ReleaseFeed.expectedDownloadURL(for: v)!,
                size: size
            )
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
/// Never launches anything.
final class ScriptedCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: [CommandResult]]
    private var invocations: [(executable: String, arguments: [String])] = []

    init(_ scripted: [String: [CommandResult]]) {
        self.scripted = scripted
    }

    var calls: [(executable: String, arguments: [String])] { lock.withLock { invocations } }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try lock.withLock {
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
    var error: UpdateError?

    var count: Int { lock.withLock { downloads.count } }

    func download(_ asset: ReleaseAsset, into directory: URL) async throws -> URL {
        lock.withLock { downloads.append(asset) }
        if let error { throw error }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(asset.name)
        try Data(repeating: 0x2A, count: asset.size).write(to: file)
        return file
    }
}

final class MockVerifier: PackageVerifying, @unchecked Sendable {
    private let lock = NSLock()
    var teamID: String? = UpdateFixtures.team
    var verifyError: UpdateError?
    private var verified: [(URL, String)] = []

    var verifications: [(URL, String)] { lock.withLock { verified } }

    func runningAppTeamID() throws -> String {
        guard let teamID else { throw UpdateError.unsignedApp }
        return teamID
    }

    func verify(packageAt url: URL, teamID: String) async throws {
        lock.withLock { verified.append((url, teamID)) }
        if let verifyError { throw verifyError }
    }
}

final class MockInstaller: UpdateInstalling, @unchecked Sendable {
    enum Outcome {
        case success
        case cancel
        case fail(String)
    }

    private let lock = NSLock()
    var outcomes: [Outcome] = [.success]
    var relaunchError: UpdateError?
    private var installed: [(URL, String, String)] = []
    private var relaunched = 0
    private var opened: [URL] = []

    var installs: [(URL, String, String)] { lock.withLock { installed } }
    var relaunchCount: Int { lock.withLock { relaunched } }
    var openedPackages: [URL] { lock.withLock { opened } }

    func install(packageAt url: URL, version: SemanticVersion, teamID: String) async throws {
        let outcome = lock.withLock { () -> Outcome in
            installed.append((url, version.text, teamID))
            return outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .success)
        }
        switch outcome {
        case .success: return
        case .cancel: throw InstallCancelled()
        case .fail(let message): throw UpdateError.install(message)
        }
    }

    @MainActor
    func relaunch() throws {
        lock.withLock { relaunched += 1 }
        if let relaunchError { throw relaunchError }
    }

    @MainActor
    func openInInstaller(_ url: URL) {
        lock.withLock { opened.append(url) }
    }
}
