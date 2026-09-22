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
    /// How many manual limit resets the account has banked, when the provider
    /// reports such a count. `nil` when it does not, and the detail window
    /// then shows no resets column at all. Optional so a status cache written
    /// before this field existed still decodes.
    let resetCreditsAvailable: Int?

    init(
        accountID: UUID,
        provider: Provider,
        email: String,
        windows: [UsageWindow],
        fetchedAt: Date,
        state: AccountState,
        planLabel: String? = nil,
        resetCreditsAvailable: Int? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.email = email
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
        self.planLabel = planLabel
        self.resetCreditsAvailable = resetCreditsAvailable
    }
}
