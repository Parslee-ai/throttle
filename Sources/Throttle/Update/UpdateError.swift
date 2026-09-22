import Foundation

/// Everything that can stop a user-initiated update, each with the sentence
/// the user sees. `UpdateController` passes `userMessage` through `Redactor`
/// before it reaches the screen, because several cases carry text that came
/// back from the network or from a subprocess.
enum UpdateError: Error, Equatable, Sendable {
    /// The running version could not be read, so there is nothing to compare.
    case unknownCurrentVersion
    /// The release server is throttling this network. `retryAt` comes from the
    /// rate-limit reset or `Retry-After` header when one was sent.
    case rateLimited(retryAt: Date?)
    /// The release server answered with a status the updater does not handle.
    case server(status: Int)
    /// The release listing arrived but could not be read.
    case unreadableFeed(String)
    /// A release exists but is not something Throttle may install; the string
    /// says why in a full sentence.
    case noInstallableUpdate(String)
    /// The request never completed.
    case network(String)
    /// The package download failed or did not match the release listing.
    case download(String)
    /// This copy of Throttle has no Developer ID team, so it has nothing to
    /// compare an update's signature against.
    case unsignedApp
    /// The package failed the signature or notarization check.
    case verification(String)
    /// The administrator install failed for a reason other than the user
    /// cancelling it.
    case install(String)
    /// The update installed but the relaunch could not be started.
    case relaunch(String)

    var userMessage: String {
        switch self {
        case .unknownCurrentVersion:
            return "Throttle couldn't read its own version number, so it can't check for updates."
        case .rateLimited(let retryAt):
            let base = "GitHub is limiting update checks from this network right now."
            guard let retryAt else { return base + " Try again later." }
            let minutes = max(1, Int((retryAt.timeIntervalSinceNow / 60).rounded(.up)))
            return base + " Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .server(let status):
            return "GitHub answered the update check with HTTP \(status). Try again later."
        case .unreadableFeed(let reason):
            return "The update information from GitHub couldn't be read (\(reason))."
        case .noInstallableUpdate(let reason):
            return reason
        case .network(let reason):
            return "Couldn't reach GitHub to check for updates: \(reason)"
        case .download(let reason):
            return "The update couldn't be downloaded: \(reason)"
        case .unsignedApp:
            return "This copy of Throttle isn't signed with a Developer ID, so it can't verify an update. Download the new version from GitHub."
        case .verification(let reason):
            return "The downloaded update failed verification and was not installed: \(reason)"
        case .install(let reason):
            return "The update couldn't be installed: \(reason)"
        case .relaunch(let reason):
            return "The update was installed, but Throttle couldn't restart itself (\(reason)). Quit and reopen Throttle to finish."
        }
    }
}

/// The user dismissed the administrator prompt. Not a failure: the controller
/// shows "Install cancelled" and offers the install again.
struct InstallCancelled: Error, Equatable, Sendable {}
