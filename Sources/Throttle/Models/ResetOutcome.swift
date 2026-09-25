import Foundation

/// What the provider answered when the user spent a banked limit reset.
///
/// Provider-neutral: each adapter maps its own answer codes onto these cases,
/// and nothing past the adapter ever sees a vendor's code. Failures that are
/// not an answer (auth, rate limit, transport, a non-2xx status) are thrown as
/// `UsageError` instead.
enum ResetOutcome: Equatable, Sendable {
    /// The provider spent a reset, or confirms this same attempt already did.
    /// Either way the account's windows changed and a fresh read is due.
    case reset
    /// No window needed a reset, so nothing was spent.
    case nothingToReset
    /// The account holds no usable reset.
    case noCredit
    /// Resets are cooling down. `until` is `nil` when the provider named no
    /// usable time.
    case cooldown(until: Date?)
    /// The provider will not reset this account now (ineligible, unavailable).
    case notAvailable
    /// A well-formed answer carrying a result this build does not know. Never
    /// treated as success.
    case unexpected
}

/// Thrown by an adapter whose provider has no reset to spend.
struct ResetUnsupportedError: Error, CustomStringConvertible {
    var description: String { "This account has no limit reset to use." }
}
