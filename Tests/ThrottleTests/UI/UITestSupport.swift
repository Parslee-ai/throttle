import Foundation
@testable import Throttle

/// Builders for the cached statuses the UI reads. No provider, no network.
enum UIFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func account(_ email: String, provider: Provider = .anthropic, sortIndex: Int = 0) -> Account {
        Account(provider: provider, email: email, sortIndex: sortIndex, addedAt: now)
    }

    static func window(_ key: String, label: String, used: Double, resetsIn: TimeInterval? = 3600) -> UsageWindow {
        UsageWindow(
            key: key,
            label: label,
            usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            durationSeconds: key == "5h" ? 18_000 : 604_800
        )
    }

    static func cached(
        for account: Account,
        windows: [UsageWindow],
        state: AccountState = .ok,
        isStale: Bool = false,
        fetchedAt: Date = now
    ) -> CachedStatus {
        let status = AccountStatus(
            accountID: account.id,
            provider: account.provider,
            email: account.email,
            windows: windows,
            fetchedAt: fetchedAt,
            state: state
        )
        return CachedStatus(
            status: status,
            lastGoodWindows: windows.isEmpty ? nil : windows,
            isStale: isStale,
            lastAttempt: fetchedAt,
            lastError: nil,
            nextAttemptAt: nil
        )
    }
}
