import SwiftUI

/// One account in the detail window (ISC-117 through ISC-124).
struct AccountRow: View {
    let account: Account
    let cached: CachedStatus?
    let planLabel: String?
    let showRemaining: Bool
    let now: Date
    let onReLogin: () -> Void

    private var windows: [UsageWindow] {
        guard let cached else { return [] }
        return cached.status.windows.isEmpty ? (cached.lastGoodWindows ?? []) : cached.status.windows
    }

    /// Secondary lanes are shown in a disclosure after the primary windows (ISC-120).
    private var primaryWindows: [UsageWindow] { windows.filter { !$0.isLane } }
    private var laneWindows: [UsageWindow] { windows.filter(\.isLane) }

    /// Windows dim whenever they are not a current, successful reading.
    private var dimmed: Bool {
        guard let cached else { return true }
        if cached.isStale { return true }
        if case .ok = cached.status.state { return false }
        return true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            identity
                .frame(width: 168, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                stateLine
                if windows.isEmpty {
                    if cached == nil {
                        Text("Waiting for first update…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(primaryWindows, id: \.key) { window in
                        bar(for: window)
                    }
                    if !laneWindows.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(laneWindows, id: \.key) { window in
                                    bar(for: window)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("More lanes (\(laneWindows.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: account.provider.symbolName)
                    .foregroundStyle(.secondary)
                Text(account.provider.displayName)
                    .font(.headline)
                if let planLabel, !planLabel.isEmpty {
                    Text(planLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .lineLimit(1)
                }
            }
            Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(account.email)
            if let cached, cached.isStale, cached.lastGoodWindows != nil {
                Text(Formatting.agePhrase(since: cached.status.fetchedAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        if let cached {
            switch cached.status.state {
            case .ok:
                EmptyView()
            case .needsLogin:
                HStack(spacing: 8) {
                    Label("Needs login", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Log in again", action: onReLogin)
                        .controlSize(.small)
                }
            case .rateLimited(let until):
                // A 429 from the provider's status endpoint, not the account's
                // own quota. Say so, or the user reads it as "my plan is out".
                Label("Status check throttled until \(Formatting.clockTime(until))", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("\(account.provider.displayName) limits how often usage can be read. This is not your plan's quota; the next check runs at \(Formatting.clockTime(until)).")
            case .error(let message):
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
        }
    }

    private func bar(for window: UsageWindow) -> some View {
        WindowBar(
            window: window,
            providerName: account.provider.displayName,
            email: account.email,
            showRemaining: showRemaining,
            dimmed: dimmed,
            now: now
        )
    }
}
