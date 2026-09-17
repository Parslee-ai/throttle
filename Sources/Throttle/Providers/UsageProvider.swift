import Foundation

/// The one seam between Throttle and a subscription vendor.
///
/// Every vendor quirk (endpoint, headers, payload shape, lane naming, token
/// refresh mechanics) lives behind a conformer in `Providers/`. The polling
/// engine and the UI depend on this protocol and on `AccountStatus` only.
protocol UsageProvider: Sendable {
    /// The case this adapter serves.
    var provider: Provider { get }

    /// Reads current usage for one account. Read-only: an implementation must
    /// never call an endpoint that spends quota or credits.
    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus

    /// Exchanges a refresh token for a rotated credential.
    ///
    /// Callers must serialise this per account and must not cancel it once
    /// started: a half-applied rotation invalidates the refresh token and locks
    /// the user out of an account that was working.
    func refresh(credential: AccountCredential) async throws -> AccountCredential
}

/// Failures an adapter can report. The poll scheduler maps these onto
/// `AccountState` and onto its backoff policy.
enum UsageError: Error {
    /// Auth was rejected (401/403 with auth semantics) or refresh failed.
    case needsLogin
    /// Provider asked us to wait. `retryAfter` comes from the response header.
    case rateLimited(retryAfter: TimeInterval?)
    /// The response was reachable but unusable; the string is a short reason.
    case invalidResponse(String)
    /// A 3xx was returned where a payload was expected, which usually means the
    /// request was bounced to a login page.
    case redirect
    /// The body exceeded the size cap, so it was dropped unread.
    case tooLarge
    /// Anything the URL loading system reported.
    case transport(Error)
}
