import Foundation

/// Health of one account as of its last fetch.
///
/// An account never disappears because of a bad fetch: it changes state and
/// keeps its row, so the user can see what went wrong and fix it.
enum AccountState: Codable, Hashable, Sendable {
    /// Last fetch succeeded and the windows are current.
    case ok
    /// Auth is gone or was rejected; the row offers a re-login.
    case needsLogin
    /// The provider is rate limiting us until the given time.
    case rateLimited(until: Date)
    /// Anything else. The string is already redacted for display.
    case error(String)
}
