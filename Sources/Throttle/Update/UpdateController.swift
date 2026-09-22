import Foundation
import Observation

/// Drives the user-initiated update: check, download, verify, install,
/// relaunch. `UpdateButton` draws `state` and calls the methods here.
///
/// Nothing in this class runs on its own. There is no launch-time or timed
/// check: the network is touched only when the user clicks.
@MainActor
@Observable
final class UpdateController {
    enum State: Equatable, Sendable {
        case idle
        case checking
        /// The running version, which is the newest published one (or newer).
        case upToDate(String)
        /// A newer published version, ready to install.
        case available(String)
        case downloading
        case verifying
        /// Waiting on the administrator prompt and then `installer`.
        case installing
        case relaunching
        /// The user dismissed the administrator prompt.
        case cancelled
        /// A redacted, user-facing message. `canOpenInInstaller` is true when a
        /// verified package is on disk and the user can finish by hand.
        case failed(String, canOpenInInstaller: Bool)
    }

    /// The environment variable that overrides the running version, so an
    /// update can be exercised end to end against a real published release.
    /// Ignored unless it holds a valid version. See `docs/RELEASING.md`.
    nonisolated static let currentVersionOverrideKey = "THROTTLE_UPDATE_CURRENT_VERSION"

    private(set) var state: State = .idle

    /// The version this copy of Throttle compares against; `nil` when neither
    /// the bundle nor the override holds a readable one.
    let currentVersion: SemanticVersion?

    @ObservationIgnored private let client: any HTTPClient
    @ObservationIgnored private let downloader: any PackageDownloading
    @ObservationIgnored private let verifier: any PackageVerifying
    @ObservationIgnored private let installer: any UpdateInstalling
    @ObservationIgnored private let cacheDirectory: URL
    /// The release the Install button installs; set by a successful check.
    @ObservationIgnored private var pendingRelease: AvailableRelease?
    /// The package that passed verification, for "Open in Installer".
    @ObservationIgnored private var verifiedPackage: URL?

    /// Production wiring.
    convenience init() {
        self.init(
            client: URLSessionHTTPClient(timeout: 15),
            downloader: PackageDownloader(),
            verifier: PackageVerifier(),
            installer: UpdateInstaller(),
            currentVersion: Self.resolveCurrentVersion(),
            cacheDirectory: Self.defaultCacheDirectory
        )
    }

    init(
        client: any HTTPClient,
        downloader: any PackageDownloading,
        verifier: any PackageVerifying,
        installer: any UpdateInstalling,
        currentVersion: SemanticVersion?,
        cacheDirectory: URL
    ) {
        self.client = client
        self.downloader = downloader
        self.verifier = verifier
        self.installer = installer
        self.currentVersion = currentVersion
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Caches/ai.parslee.throttle/Updates`.
    nonisolated static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.parslee.throttle", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// `THROTTLE_UPDATE_CURRENT_VERSION` when it holds a valid version,
    /// otherwise the bundle's `CFBundleShortVersionString`.
    nonisolated static func resolveCurrentVersion(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SemanticVersion? {
        if let override = environment[currentVersionOverrideKey],
           SemanticVersion.isValid(override),
           let version = SemanticVersion(override) {
            return version
        }
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return SemanticVersion(short)
    }

    /// Whether a step is in flight, so a second click does nothing.
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing, .relaunching: return true
        case .idle, .upToDate, .available, .cancelled, .failed: return false
        }
    }

    // MARK: Actions

    /// Asks for the newest published release. Single-flight: a click while a
    /// step is running is ignored. The returned task is for tests.
    @discardableResult
    func checkForUpdates() -> Task<Void, Never> {
        guard !isBusy else { return Task {} }
        guard let currentVersion else {
            fail(UpdateError.unknownCurrentVersion)
            return Task {}
        }
        pendingRelease = nil
        verifiedPackage = nil
        state = .checking
        let feed = ReleaseFeed(client: client, currentVersion: currentVersion)
        return Task {
            do {
                switch try await feed.check() {
                case .upToDate:
                    state = .upToDate(currentVersion.text)
                case .available(let release):
                    pendingRelease = release
                    state = .available(release.version.text)
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Downloads, verifies, and installs the release the last check found,
    /// then relaunches. The returned task is for tests.
    @discardableResult
    func installUpdate() -> Task<Void, Never> {
        guard !isBusy, let release = pendingRelease else { return Task {} }
        verifiedPackage = nil

        // Refuse before downloading anything: an ad-hoc build has no team to
        // hold the package's signature against.
        let teamID: String
        do {
            teamID = try verifier.runningAppTeamID()
        } catch {
            fail(error)
            return Task {}
        }

        state = .downloading
        return Task {
            do {
                let package = try await downloader.download(release.asset, into: cacheDirectory)
                state = .verifying
                try await verifier.verify(packageAt: package, teamID: teamID)
                verifiedPackage = package
                state = .installing
                try await installer.install(packageAt: package, version: release.version, teamID: teamID)
                try? FileManager.default.removeItem(at: package)
                verifiedPackage = nil
                // Installed: a retry after a failed relaunch re-checks rather
                // than asking for the administrator password again.
                pendingRelease = nil
                state = .relaunching
                try installer.relaunch()
            } catch is InstallCancelled {
                state = .cancelled
            } catch {
                fail(error)
            }
        }
    }

    /// The failed state's retry: installs again when a release is known,
    /// otherwise checks again.
    @discardableResult
    func retry() -> Task<Void, Never> {
        pendingRelease == nil ? checkForUpdates() : installUpdate()
    }

    /// Opens the verified package in Installer after an install failure.
    func openInInstaller() {
        guard let verifiedPackage else { return }
        installer.openInInstaller(verifiedPackage)
    }

    private func fail(_ error: any Error) {
        let message: String
        if let update = error as? UpdateError {
            message = update.userMessage
        } else {
            message = error.localizedDescription
        }
        let fallback: Bool
        if case .install = error as? UpdateError, let verifiedPackage,
           FileManager.default.fileExists(atPath: verifiedPackage.path) {
            fallback = true
        } else {
            fallback = false
        }
        state = .failed(Redactor.redact(message), canOpenInInstaller: fallback)
    }
}
