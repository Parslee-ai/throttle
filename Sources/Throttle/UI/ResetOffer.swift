import Foundation

/// What a "Manual resets" column offers: which kinds can be started, why the
/// others cannot, and whether the Use reset button works. One rule for the
/// button, the "…" menu, the right-click menu and the confirmation.
///
/// Provider-neutral: it reads only the row's kinds, its total, whether the
/// row is dimmed, and the gate an unsettled attempt leaves on the account.
struct ResetOffer {
    /// The kinds the row lists, in display order. Empty means one unnamed
    /// kind, drawn as a single "N available".
    let kinds: [ResetKind]
    /// The row's total, spendable now or not.
    let count: Int
    let dimmed: Bool
    let gate: ResetGate?
    let now: Date

    init(count: Int, kinds: [ResetKind]?, dimmed: Bool, gate: ResetGate?, now: Date) {
        self.kinds = Self.merged(kinds ?? [])
        self.count = count
        self.dimmed = dimmed
        self.gate = gate
        self.now = now
    }

    var hasKinds: Bool { !kinds.isEmpty }

    /// One entry per kind, in the order given. Two entries of one kind draw
    /// as one line with their counts added, spendable when either is.
    static func merged(_ kinds: [ResetKind]) -> [ResetKind] {
        var result: [ResetKind] = []
        for kind in kinds {
            guard let index = result.firstIndex(where: { $0.key == kind.key }) else {
                result.append(kind)
                continue
            }
            let first = result[index]
            let reason = first.isSpendable || kind.isSpendable ? nil : first.reason
            result[index] = ResetKind(key: first.key, label: first.label, count: first.count + kind.count, reason: reason)
        }
        return result
    }

    /// The kind an unsettled attempt may be retried for, when one is pending
    /// on a row with kinds.
    var retryKind: ResetKind.Key? {
        guard hasKinds, case .retryOnly(let kind?, _) = gate else { return nil }
        return kind
    }

    /// The label the retry is for: the kind's label as it read when the
    /// attempt started, else as it reads now.
    var retryLabel: String? {
        guard let kind = retryKind, case .retryOnly(_, let label) = gate else { return nil }
        return label ?? kinds.first { $0.key == kind }?.label ?? ResetKind.fallbackLabel
    }

    /// Why this kind cannot be started from this row now, or `nil` when it
    /// can. A pending retry is offered whatever the latest reading says
    /// about its kind; every other kind waits for it.
    func reason(for kind: ResetKind) -> String? {
        if case .awaitingReading = gate { return ResetMessages.waitingForFreshReading }
        if let retry = retryKind {
            return kind.key == retry ? nil : ResetMessages.finishEarlierReset
        }
        return kind.reason.map { ResetMessages.lineReason(for: $0, kindLabel: kind.label, now: now) }
    }

    /// Why the Use reset button is greyed, or `nil` when it works.
    var disabledReason: String? {
        if case .awaitingReading = gate { return ResetMessages.waitingForFreshReading }
        guard hasKinds else { return Self.disabledReason(count: count, dimmed: dimmed) }
        if dimmed { return "Refresh this account first" }
        if retryKind != nil { return nil }
        if kinds.contains(where: { reason(for: $0) == nil }) { return nil }
        if kinds.allSatisfy({ $0.count == 0 }) { return ResetMessages.noResets }
        if kinds.count == 1, let only = kinds.first, let reason = reason(for: only) { return reason }
        return ResetMessages.noKindSpendable
    }

    /// The rule for a row with one unnamed kind, unchanged from before kinds.
    static func disabledReason(count: Int, dimmed: Bool) -> String? {
        if count <= 0 { return ResetMessages.noResets }
        if dimmed { return "Refresh this account first" }
        return nil
    }

    /// The button's tooltip when it works.
    var enabledHelp: String {
        if let label = retryLabel { return "Retry the earlier \(label)" }
        return "Spend one banked reset for this account"
    }

    // MARK: Spoken text

    /// `Manual resets: 2 Full reset, 1 <model> reset`.
    var columnAccessibilityLabel: String {
        "Manual resets: " + kinds.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
    }

    /// `1 <model> reset`, or `1 <model> reset, unavailable: Paused` for a kind
    /// that cannot be started.
    func lineAccessibilityLabel(for kind: ResetKind) -> String {
        let line = "\(kind.count) \(kind.label)"
        guard let reason = reason(for: kind) else { return line }
        return "\(line), unavailable: \(reason)"
    }
}
