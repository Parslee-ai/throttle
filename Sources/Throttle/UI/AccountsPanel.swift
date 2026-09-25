import SwiftUI

/// What the account list can ask its owner to do, per account.
struct AccountsPanelActions {
    var refresh: @MainActor (Account) -> Void = { _ in }
    var retryStatusCheck: @MainActor (Account) -> Void = { _ in }
    var reLogin: @MainActor (Account) -> Void = { _ in }
    var moveUp: @MainActor (Account) -> Void = { _ in }
    var moveDown: @MainActor (Account) -> Void = { _ in }
    /// A drag inside one provider section, in `onMove` terms for that
    /// section's rows.
    var moveInSection: @MainActor (Provider, IndexSet, Int) -> Void = { _, _, _ in }
    var rename: @MainActor (Account, String) -> Void = { _, _ in }
    var remove: @MainActor (Account) -> Void = { _ in }
    /// Asks for the reset confirmation for the account.
    var useReset: @MainActor (Account) -> Void = { _ in }
    var dismissResetNotice: @MainActor (Account) -> Void = { _ in }
}

/// Every account, one section per provider, drawn from plain data: the
/// accounts, their cached statuses, their plans, and the time. `DetailWindow`
/// feeds it from `AppModel`; the snapshot test feeds it fixtures.
///
/// It is a `List`, so rows can be dragged into a new order within their
/// section (ISC-92); on macOS `onMove` works without an edit mode. Each row
/// reports its height so the window hugs the content up to
/// `PopupMetrics.maxListHeight`, then scrolls.
struct AccountsPanel: View {
    let accounts: [Account]
    let statuses: [UUID: CachedStatus]
    let planLabels: [UUID: String]
    let now: Date
    var actions = AccountsPanelActions()
    /// Accounts with a reset running.
    var resetsInFlight: Set<UUID> = []
    /// Each account's reset message, if one is showing.
    var resetNotices: [UUID: ResetNotice] = [:]

    @State private var reportedHeights: [String: CGFloat] = [:]

    private var sections: [AccountOrder.Section] { AccountOrder.sections(accounts) }

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.element.id) { offset, section in
                header(for: section, isFirst: offset == 0)
                    .measured(Self.headerKey(offset))
                    .listRowInsets(Self.rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                ForEach(section.entries) { entry in
                    row(for: entry, in: section)
                        .measured(entry.id.uuidString)
                        .listRowInsets(Self.rowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    actions.moveInSection(section.provider, source, destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .onPreferenceChange(RowHeightsKey.self) { heights in
            reportedHeights = heights
        }
        .frame(height: min(listHeight, PopupMetrics.maxListHeight))
    }

    // MARK: Height

    /// Rows a lazy `List` has not rendered yet report no height. Sizing the
    /// list only from reported rows starves the rest: at height 1 only the
    /// first row renders, so only the first row reports, so the list stays one
    /// row tall until something else forces a relayout. Every unreported row
    /// counts at an estimate so all rows get laid out, then real heights take
    /// over.
    static let estimatedRowHeight: CGFloat = 72
    static let estimatedHeaderHeight: CGFloat = 44

    private var listHeight: CGFloat {
        var total: CGFloat = 0
        for (offset, section) in sections.enumerated() {
            total += reportedHeights[Self.headerKey(offset)] ?? Self.estimatedHeaderHeight
            for entry in section.entries {
                total += reportedHeights[entry.id.uuidString] ?? Self.estimatedRowHeight
            }
        }
        return max(total, 1)
    }

    private static func headerKey(_ offset: Int) -> String { "section-\(offset)" }

    /// Cancels the plain list's own horizontal cell inset, so every row spans
    /// the full window width like the header and footer.
    private static let rowInsets = EdgeInsets(
        top: 0,
        leading: -PopupMetrics.listCellInset,
        bottom: 0,
        trailing: -PopupMetrics.listCellInset
    )

    // MARK: Pieces

    private func header(for section: AccountOrder.Section, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.provider.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(section.entries.count)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.leading, PopupMetrics.horizontalPadding)
        .padding(.top, isFirst ? 14 : 14 + PopupMetrics.sectionSpacing)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(for entry: AccountOrder.Entry, in section: AccountOrder.Section) -> some View {
        let account = entry.account
        let isFirst = section.entries.first?.id == entry.id
        let isLast = section.entries.last?.id == entry.id
        return VStack(spacing: 0) {
            AccountRow(
                account: account,
                number: entry.number,
                cached: statuses[account.id],
                planLabel: planLabels[account.id],
                now: now,
                isFirstInSection: isFirst,
                isLastInSection: isLast,
                actions: AccountRowActions(
                    refresh: { actions.refresh(account) },
                    retryStatusCheck: { actions.retryStatusCheck(account) },
                    reLogin: { actions.reLogin(account) },
                    moveUp: { actions.moveUp(account) },
                    moveDown: { actions.moveDown(account) },
                    rename: { actions.rename(account, $0) },
                    remove: { actions.remove(account) },
                    useReset: { actions.useReset(account) },
                    dismissResetNotice: { actions.dismissResetNotice(account) }
                ),
                isResetting: resetsInFlight.contains(account.id),
                resetNotice: resetNotices[account.id]
            )
            if !isLast {
                Rectangle()
                    .fill(Colors.divider)
                    .frame(height: 1)
                    .padding(.leading, PopupMetrics.horizontalPadding)
            }
        }
    }
}

private extension View {
    /// Reports this view's height under `key` to the enclosing list.
    func measured(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: RowHeightsKey.self, value: [key: proxy.size.height])
        })
    }
}

private struct RowHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
