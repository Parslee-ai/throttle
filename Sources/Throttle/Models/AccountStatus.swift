import Foundation

/// Everything the UI needs to draw one account row. This is the only shape the
/// UI layer sees; it never touches provider payloads.
struct AccountStatus: Hashable, Sendable {
    let accountID: UUID
    let provider: Provider
    let email: String
    /// Windows in provider-defined display order.
    let windows: [UsageWindow]
    /// When this status was produced, used to render staleness.
    let fetchedAt: Date
    let state: AccountState

    init(
        accountID: UUID,
        provider: Provider,
        email: String,
        windows: [UsageWindow],
        fetchedAt: Date,
        state: AccountState
    ) {
        self.accountID = accountID
        self.provider = provider
        self.email = email
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
    }
}
