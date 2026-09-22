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

    /// A login for this account just finished, new or repeated. Anything the
    /// adapter remembered about the account from before is out of date.
    func accountDidSignIn(_ accountID: UUID) async
}

extension UsageProvider {
    func accountDidSignIn(_ accountID: UUID) async {}
}

/// How much of the current fetch's time budget is left.
///
/// The poll scheduler times credential resolution and the usage read as one
/// fetch and binds this for its duration. An adapter that does optional,
/// best-effort work after its usage read checks it first, so that extra work
/// can never turn a good reading into a timeout. Unbound (`nil`) outside a
/// scheduled fetch, such as during a login.
enum FetchBudget {
    @TaskLocal static var remaining: (@Sendable () -> TimeInterval)?
}

/// Failures an adapter can report. The poll scheduler maps these onto
/// `AccountState` and onto its backoff policy.
enum UsageError: Error {
    /// Auth was rejected (401, or a 403 without a permission body) or refresh
    /// failed. A re-login is the fix.
    case needsLogin
    /// The provider refused this client for the account's organization (a 403
    /// with a permission error). A re-login cannot fix it, and repeating the
    /// request only earns a 429. `reason` is the provider's message, already
    /// passed through `Redactor`.
    case forbidden(reason: String)
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
