import Foundation

/// Everything the UI needs to draw one account row. This is the only shape the
/// UI layer sees; it never touches provider payloads.
struct AccountStatus: Codable, Hashable, Sendable {
    let accountID: UUID
    let provider: Provider
    let email: String
    /// Windows in provider-defined display order.
    let windows: [UsageWindow]
    /// When this status was produced, used to render staleness.
    let fetchedAt: Date
    let state: AccountState
    /// The subscription tier the provider reported with this reading, such as
    /// `pro` or `max`, for the badge next to the email (ISC-74). `nil` when
    /// the payload carries no plan.
    let planLabel: String?

    init(
        accountID: UUID,
        provider: Provider,
        email: String,
        windows: [UsageWindow],
        fetchedAt: Date,
        state: AccountState,
        planLabel: String? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.email = email
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
        self.planLabel = planLabel
    }
}
