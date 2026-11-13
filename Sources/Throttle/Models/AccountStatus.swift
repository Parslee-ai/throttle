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
    /// before this field existed still decodes. When `resetKinds` is present
    /// this is always their total, spendable now or not.
    let resetCreditsAvailable: Int?
    /// The banked resets by kind, in the fixed display order of
    /// `ResetKind.Key`, one entry per kind. `nil` means the provider reports
    /// one unnamed kind, counted by `resetCreditsAvailable` alone, as Codex
    /// does; such a status encodes exactly as it did before kinds existed.
    let resetKinds: [ResetKind]?

    init(
        accountID: UUID,
        provider: Provider,
        email: String,
        windows: [UsageWindow],
        fetchedAt: Date,
        state: AccountState,
        planLabel: String? = nil,
        resetCreditsAvailable: Int? = nil,
        resetKinds: [ResetKind]? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.email = email
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
        self.planLabel = planLabel
        // Sorted here so every adapter and every cache rebuild agrees on the
        // order, and two readings of the same payload compare equal.
        let kinds = resetKinds?.enumerated()
            .sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }
            .map(\.element)
        self.resetKinds = kinds
        self.resetCreditsAvailable = kinds.map { $0.reduce(0) { $0 + $1.count } } ?? resetCreditsAvailable
    }
}
