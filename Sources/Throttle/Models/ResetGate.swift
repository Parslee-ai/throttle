import Foundation

/// What a row may offer while an earlier reset attempt on its account is
/// unsettled. No gate means the row offers its kinds as usual.
///
/// Provider-neutral and memory only: it names a kind, never a grant or an
/// attempt, and it does not outlive the process.
enum ResetGate: Equatable, Sendable {
    /// An attempt for this kind got no definite answer, so the reset may or
    /// may not have been spent. Only a retry of the same kind is offered,
    /// whatever the latest reading says about that kind. `label` is the
    /// kind's label as it read when the attempt started, `nil` on a row with
    /// one unnamed kind.
    case retryOnly(kind: ResetKind.Key?, label: String?)
    /// An unsettled attempt was closed without a definite answer. No reset of
    /// any kind is offered until the account's next successful reading, so
    /// the next click is made against the provider's fresh counts.
    case awaitingReading
}
