import Foundation

/// How one user-initiated reset attempt ended, as the scheduler reports it to
/// the app. Provider-neutral: the adapter's answer arrives as a
/// `ResetOutcome`, and every failure that is not an answer is classified here
/// so nothing past the scheduler ever inspects a `UsageError`.
enum ResetResult: Equatable, Sendable {
    /// The provider answered. `.reset` covers "this same attempt already went
    /// through".
    case outcome(ResetOutcome)
    /// The provider asked us to wait. `until` is when to try again, `nil`
    /// when it named no time. The poll backoff is not moved.
    case rateLimited(until: Date?)
    /// Auth was rejected even after one forced refresh, or the refresh itself
    /// failed. The account is flagged `needsLogin` in the cache; its row stays.
    case needsLogin
    /// The provider refuses this client the reset. `reason` is the provider's
    /// message, already redacted. The account is not signed out.
    case forbidden(reason: String)
    /// A non-2xx status the other cases do not cover. A 5xx may have come
    /// after the provider spent the reset, so it is never reported as
    /// "nothing changed".
    case providerError(status: Int)
    /// Transport failure or timeout. The reset may or may not have landed, so
    /// a retry must reuse the same attempt id.
    case unreachable
    /// A reply that could not be understood (unparseable, over the size cap).
    /// Never treated as success.
    case unexpected
    /// The account's provider has no reset to spend.
    case unsupported
    /// A reset for this account is already running; nothing was sent.
    case alreadyRunning

    /// Whether the account's usage is read once right after this result, so
    /// the row shows the provider's own numbers: after a spend, after any
    /// answer that means the count the row shows is out of date, and after a
    /// 5xx, which a gateway can return after the provider already spent.
    var wantsUsageRead: Bool {
        switch self {
        case .outcome(.reset), .outcome(.noCredit), .outcome(.notAvailable), .outcome(.unexpected), .unexpected:
            return true
        case .providerError(let status):
            return status >= 500
        default:
            return false
        }
    }
}
