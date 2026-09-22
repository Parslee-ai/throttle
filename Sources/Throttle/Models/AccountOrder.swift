import Foundation

/// The one order accounts are shown in: grouped by provider in
/// `Provider.allCases` order, and by `sortIndex` within a provider.
///
/// The detail window's numbering, the menu bar's number, and the rotation all
/// read the list this produces, so the number beside an account in the window
/// is the number the bar shows for it and the order the bar rotates through.
enum AccountOrder {
    /// One provider's accounts, each with its 1-based number in the full
    /// display order.
    struct Section: Identifiable, Hashable, Sendable {
        let provider: Provider
        let entries: [Entry]
        var id: Provider { provider }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        /// 1-based position in the display order.
        let number: Int
        let account: Account
        var id: UUID { account.id }
    }

    /// Display order: provider sections first, then `sortIndex`, then
    /// `addedAt`, the same tie-break the store uses.
    static func grouped(_ accounts: [Account]) -> [Account] {
        let rank = Dictionary(uniqueKeysWithValues: Provider.allCases.enumerated().map { ($1, $0) })
        return accounts.sorted { lhs, rhs in
            let left = rank[lhs.provider] ?? Int.max
            let right = rank[rhs.provider] ?? Int.max
            if left != right { return left < right }
            return storeOrdered(lhs, rhs)
        }
    }

    /// The display order split into non-empty provider sections.
    static func sections(_ accounts: [Account]) -> [Section] {
        let ordered = grouped(accounts)
        let numbered = ordered.enumerated().map { Entry(number: $0.offset + 1, account: $0.element) }
        return Provider.allCases.compactMap { provider in
            let entries = numbered.filter { $0.account.provider == provider }
            return entries.isEmpty ? nil : Section(provider: provider, entries: entries)
        }
    }

    /// The 1-based number of an account in the display order.
    static func number(of id: UUID, in accounts: [Account]) -> Int? {
        grouped(accounts).firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Translates a move inside one provider section into the global index
    /// `AccountStore.move(id:to:)` expects.
    ///
    /// `storeOrder` is the store's own list (`sortIndex` order), where the
    /// providers may be interleaved. The account lands directly before the
    /// section neighbour it should precede, or directly after the last one,
    /// so its position among other providers' accounts never matters and it
    /// can never leave its section. Returns `nil` when nothing would change.
    static func storeIndex(moving id: UUID, toSectionPosition position: Int, storeOrder: [Account]) -> Int? {
        guard let account = storeOrder.first(where: { $0.id == id }) else { return nil }
        let section = grouped(storeOrder).filter { $0.provider == account.provider }
        guard let from = section.firstIndex(where: { $0.id == id }) else { return nil }
        let target = min(max(position, 0), section.count - 1)
        guard target != from else { return nil }

        let rest = section.filter { $0.id != id }
        let others = storeOrder.filter { $0.id != id }
        if target < rest.count {
            return others.firstIndex { $0.id == rest[target].id }
        }
        guard let last = rest.last, let anchor = others.firstIndex(where: { $0.id == last.id }) else { return nil }
        return anchor + 1
    }

    private static func storeOrdered(_ lhs: Account, _ rhs: Account) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.addedAt < rhs.addedAt
    }
}
