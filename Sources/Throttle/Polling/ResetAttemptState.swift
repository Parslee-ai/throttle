import Foundation

/// Where an account's reset attempt stands, for a provider with a retry
/// window (`UsageProvider.resetRetryWindow`). Provider-neutral and memory
/// only: it names a kind and the app's own attempt id, never a grant.
enum ResetAttemptState: Equatable, Sendable {
    /// An attempt went unanswered and may be retried, with the same id and
    /// kind, until `until`.
    case retryable(attemptID: UUID, choice: ResetKind.Key?, until: Date)
    /// An unanswered attempt was closed without a definite answer. No new
    /// attempt is accepted until a usage read made afterwards succeeds.
    case awaitingReading
}

/// How a reset result leaves the attempt that produced it.
enum ResetAttemptEnding: Equatable, Sendable {
    /// The provider said what happened to this attempt.
    case definitive
    /// The request was turned away before it was processed, or the adapter
    /// sent nothing (the kind is blocked, a reading is needed).
    case refused
    /// The reset may or may not have been spent.
    case ambiguous
    /// Nothing was sent (a second click during a run).
    case nothingHappened
}

extension ResetResult {
    var attemptEnding: ResetAttemptEnding {
        switch self {
        case .outcome(.reset), .outcome(.nothingToReset), .outcome(.noCredit),
             .outcome(.cooldown), .outcome(.notAvailable), .unsupported:
            return .definitive
        case .needsLogin, .forbidden, .rateLimited, .outcome(.blocked), .outcome(.needsFreshReading):
            return .refused
        case .providerError(let status):
            return (300..<500).contains(status) ? .refused : .ambiguous
        case .outcome(.unexpected), .unexpected, .unreachable:
            return .ambiguous
        case .alreadyRunning:
            return .nothingHappened
        }
    }

    /// The provider's answer that it did not spend this send. After an
    /// unanswered earlier send it proves nothing about that one.
    var isRefusalAnswer: Bool {
        switch self {
        case .outcome(.nothingToReset), .outcome(.cooldown), .outcome(.notAvailable), .outcome(.noCredit):
            return true
        default:
            return false
        }
    }
}

/// The retry window closed before a send went out, so nothing was sent.
struct RetryWindowClosedError: Error {}
