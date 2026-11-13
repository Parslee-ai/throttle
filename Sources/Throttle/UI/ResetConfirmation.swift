import SwiftUI

/// The question asked before a banked reset is spent: which account, how many
/// resets it holds, that it cannot be undone, and how much of each window is
/// left right now, so spending one while a window still has room is a visible
/// choice.
///
/// On a row with kinds it also says which kind: with one kind the title names
/// it; with several, the owner picks one from a list, nothing is picked in
/// advance, and "Use reset" stays greyed until they do. While an earlier
/// attempt waits for its retry, the card offers that retry only.
///
/// Drawn as a `ConfirmationCard` on a panel modal, not a SwiftUI `alert`.
/// On macOS an alert makes its first non-cancel button the Return key's
/// target, which here would be "Use reset", and it is a window of its own,
/// which closes the detail panel when clicked. The card makes **Cancel** the
/// default button (Return) and the cancel action (Escape) and gives it the
/// initial focus, so no key pressed alone ever spends a reset. "Use reset"
/// has no shortcut: it takes a click, or Tab to it and Space.
struct ResetConfirmation: View {
    /// What the owner confirmed.
    struct Choice: Equatable {
        /// The kind picked, `nil` on a row with no kinds.
        let kind: ResetKind.Key?
        /// Its label as the card showed it.
        let label: String?
        /// A retry of an unsettled attempt, not a new one.
        let retrying: Bool
    }

    /// What confirming leads to, decided against the account as it is when
    /// the owner confirms, not as it was when the card opened.
    enum Outcome: Equatable {
        case send(kind: ResetKind.Key?, retrying: Bool)
        /// Nothing is sent. With a reason, the row says why.
        case hold(ResetKind.Reason?, label: String?)
    }

    let displayName: String
    let count: Int
    /// The row's primary windows, in the row's order.
    let windows: [UsageWindow]
    let kinds: [ResetKind]
    /// The gate on the account when the card opened.
    let gate: ResetGate?
    let now: Date
    let onChoice: @MainActor (Choice) -> Void
    let onCancel: @MainActor () -> Void

    @State private var picked: ResetKind.Key?
    /// Each kind's label as the card first showed it, so a pick whose kind
    /// has since left the list still names it in the row's message.
    @State private var openingLabels: [ResetKind.Key: String]

    /// A row with no kinds.
    init(
        displayName: String,
        count: Int,
        windows: [UsageWindow],
        onConfirm: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.init(displayName: displayName, count: count, windows: windows, kinds: nil, gate: nil,
                  onChoice: { _ in onConfirm() }, onCancel: onCancel)
    }

    init(
        displayName: String,
        count: Int,
        windows: [UsageWindow],
        kinds: [ResetKind]?,
        gate: ResetGate?,
        now: Date = Date(),
        picked: ResetKind.Key? = nil,
        onChoice: @escaping @MainActor (Choice) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.displayName = displayName
        self.count = count
        self.windows = windows
        self.kinds = ResetOffer.merged(kinds ?? [])
        self.gate = gate
        self.now = now
        self.onChoice = onChoice
        self.onCancel = onCancel
        // A card that opens on one kind has that kind picked from the start,
        // so a reading that swaps the kind while it is open cannot move the
        // confirmation onto another one.
        var opening = picked
        if opening == nil, self.kinds.count == 1, !Self.isRetry(gate) { opening = self.kinds.first?.key }
        _picked = State(initialValue: opening)
        _openingLabels = State(initialValue: Dictionary(self.kinds.map { ($0.key, $0.label) }) { first, _ in first })
    }

    /// Confirms a row with no kinds.
    var onConfirm: @MainActor () -> Void {
        let onChoice = onChoice
        let retrying = isRetry
        return { onChoice(Choice(kind: nil, label: nil, retrying: retrying)) }
    }

    private var offer: ResetOffer {
        ResetOffer(count: count, kinds: kinds, dimmed: false, gate: gate, now: now)
    }

    private var isRetry: Bool { Self.isRetry(gate) }

    private static func isRetry(_ gate: ResetGate?) -> Bool {
        if case .retryOnly = gate { return true }
        return false
    }

    // MARK: Words

    static func title(count: Int, displayName: String) -> String {
        "Use 1 of \(count) \(count == 1 ? "reset" : "resets") for \(displayName)?"
    }

    /// `Use 1 of 2 Full resets for Work?`
    static func title(kind: ResetKind, displayName: String) -> String {
        "Use 1 of \(kind.count) \(plural(kind.label, count: kind.count)) for \(displayName)?"
    }

    /// `Retry Full reset for Work?`
    static func retryTitle(label: String, displayName: String) -> String {
        "Retry \(label) for \(displayName)?"
    }

    static func pickTitle(displayName: String) -> String {
        "Use a reset for \(displayName)?"
    }

    /// `Full resets` for more than one; a label that does not end in "reset"
    /// is left as it is rather than guessed at.
    static func plural(_ label: String, count: Int) -> String {
        guard count != 1, label.lowercased().hasSuffix("reset") else { return label }
        return label + "s"
    }

    static let warning = "A reset can't be undone."
    static let retryNote = "The earlier attempt got no clear answer. A retry never spends a second reset."

    /// `7-day limit: 30% left`, one line per window.
    static func windowLines(_ windows: [UsageWindow]) -> [String] {
        windows.map { "\(Formatting.longLabel(for: $0)): \(Formatting.remainingPercent(used: $0.usedPercent))% left" }
    }

    /// What a model refill does, in the row's own window names: `Refills
    /// 7-day <model> and returns its share to the 7-day limit. Other weekly
    /// usage stays as it is.` The model's window is the model-scoped window
    /// the kind's label names, or the only one there is.
    static func modelRefillLine(kindLabel: String, windows: [UsageWindow]) -> String {
        let model = ResetMessages.modelName(fromKindLabel: kindLabel)
        let scoped = windows.filter(\.isModelScoped)
        let modelWindow = scoped.first { $0.label.caseInsensitiveCompare(model) == .orderedSame }
            ?? (scoped.count == 1 ? scoped.first : nil)
        guard let modelWindow else {
            return "Refills one model's weekly usage and returns its share to the weekly limit. Other weekly usage stays as it is."
        }
        let shared = windows.first { !$0.isModelScoped && !$0.isLane && $0.durationSeconds == modelWindow.durationSeconds }
        let limit = shared.map(Formatting.longLabel(for:)) ?? "weekly limit"
        return "Refills \(Formatting.longLabel(for: modelWindow)) and returns its share to the \(limit). Other weekly usage stays as it is."
    }

    // MARK: Deciding

    /// Whether a confirmed choice is sent, checked against the account's
    /// latest reading and gate. A new attempt is sent only for a kind the
    /// latest reading still lists as spendable; a kind that dropped to 0,
    /// vanished or became blocked sends nothing and is never swapped for
    /// another. A retry is sent only while its gate still stands, so a card
    /// left open past a refusal or the retry's lifetime sends nothing.
    static func outcome(of choice: Choice, status: AccountStatus?, gate: ResetGate?) -> Outcome {
        if choice.retrying {
            guard case .retryOnly(let kind, _) = gate, kind == choice.kind else { return .hold(nil, label: nil) }
            return .send(kind: kind, retrying: true)
        }
        guard gate == nil else { return .hold(nil, label: nil) }
        let kinds = status?.resetKinds ?? []
        guard let key = choice.kind else {
            // Kinds learnt after the card opened: the owner picks again.
            return kinds.isEmpty ? .send(kind: nil, retrying: false) : .hold(nil, label: nil)
        }
        guard let kind = kinds.first(where: { $0.key == key }) else { return .hold(.noneLeft, label: choice.label) }
        if let reason = kind.reason { return .hold(reason, label: kind.label) }
        return .send(kind: key, retrying: false)
    }

    /// The row's message for a confirmed choice that was held back for a
    /// reason, worded as the same refusal from the provider would be.
    /// `otherKindSpendable` says another kind on the row can still be spent.
    static func heldNotice(for outcome: Outcome, providerName: String, now: Date,
                           otherKindSpendable: Bool = false) -> ResetNotice? {
        guard case .hold(let reason?, let label) = outcome else { return nil }
        return ResetMessages.notice(for: .outcome(.blocked(reason)), providerName: providerName, now: now,
                                    kindLabel: label, otherKindSpendable: otherKindSpendable)
    }

    // MARK: Drawing

    /// The kind the card would spend, when it has one. The pick stands when a
    /// reading drops its kind while the card is open: confirming it then
    /// sends nothing and the row says why. The card never moves onto a kind
    /// the owner did not pick.
    private var chosenKind: ResetKind.Key? {
        offer.retryKind ?? picked
    }

    private var pickIsListed: Bool {
        kinds.contains { $0.key == picked }
    }

    private var chosenLabel: String? {
        if let label = offer.retryLabel { return label }
        guard let key = chosenKind else { return nil }
        return kinds.first { $0.key == key }?.label ?? openingLabels[key]
    }

    private var title: String {
        guard offer.hasKinds else { return Self.title(count: count, displayName: displayName) }
        if let label = offer.retryLabel { return Self.retryTitle(label: label, displayName: displayName) }
        if kinds.count == 1, let only = kinds.first, only.key == picked {
            return Self.title(kind: only, displayName: displayName)
        }
        return Self.pickTitle(displayName: displayName)
    }

    /// The list is drawn when there is something to tell apart: several
    /// kinds, a retry beside other kinds (even when the retried kind is no
    /// longer listed), or a kind the owner has not picked.
    private var showsPicker: Bool {
        if let retry = offer.retryKind { return kinds.contains { $0.key != retry } }
        return kinds.count > 1 || (!kinds.isEmpty && !pickIsListed)
    }

    var body: some View {
        ConfirmationCard(
            title: title,
            confirmTitle: "Use reset",
            confirmDisabled: offer.hasKinds && chosenKind == nil,
            onConfirm: confirm,
            onCancel: onCancel
        ) {
            if showsPicker {
                ResetKindPicker(
                    kinds: kinds,
                    reason: { offer.reason(for: $0) },
                    picked: offer.retryKind == nil ? $picked : .constant(offer.retryKind)
                )
            }
            if offer.retryKind != nil {
                Text(Self.retryNote)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if chosenKind == .modelRefill, let label = chosenLabel {
                Text(Self.modelRefillLine(kindLabel: label, windows: windows))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.warning)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Left right now")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ForEach(Self.windowLines(windows), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13).monospacedDigit())
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func confirm() {
        guard offer.hasKinds else { return onConfirm() }
        guard let kind = chosenKind else { return }
        onChoice(Choice(kind: kind, label: chosenLabel, retrying: offer.retryKind != nil))
    }
}

/// The confirmation's list of kinds: one line per kind with its count, a
/// mark on the picked one, and blocked kinds greyed with their reason beside
/// them. Tab reaches it, the arrow keys move between kinds that can be
/// picked, and Space picks; a blocked kind cannot be picked by click or key.
/// Return and Escape are left to the card, so neither ever picks or confirms.
struct ResetKindPicker: View {
    let kinds: [ResetKind]
    /// Why a kind cannot be picked, or `nil` when it can.
    let reason: (ResetKind) -> String?
    @Binding var picked: ResetKind.Key?

    @FocusState private var focused: Bool
    /// The kind the arrow keys are on.
    @State private var cursor: ResetKind.Key?

    /// The pickable kind `step` places from `current`, wrapping round;
    /// blocked kinds are skipped. With nothing current, the first pickable
    /// kind (or the last, moving up).
    static func move(from current: ResetKind.Key?, by step: Int, in pickable: [ResetKind.Key]) -> ResetKind.Key? {
        guard !pickable.isEmpty else { return nil }
        guard let current, let index = pickable.firstIndex(of: current) else {
            return step < 0 ? pickable.last : pickable.first
        }
        let count = pickable.count
        return pickable[((index + step) % count + count) % count]
    }

    private var pickable: [ResetKind.Key] { kinds.filter { reason($0) == nil }.map(\.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(kinds, id: \.key) { kind in
                line(kind)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor : Colors.divider, lineWidth: focused ? 2 : 1)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused, cursor == nil { cursor = picked ?? pickable.first }
        }
        .onKeyPress(.downArrow) {
            cursor = Self.move(from: cursor, by: 1, in: pickable)
            return .handled
        }
        .onKeyPress(.upArrow) {
            cursor = Self.move(from: cursor, by: -1, in: pickable)
            return .handled
        }
        .onKeyPress(.space) {
            if let cursor, pickable.contains(cursor) { picked = cursor }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reset to use")
    }

    /// A plain button rather than a tap gesture: a button takes the click
    /// that brings the panel forward, and VoiceOver's press, with no extra
    /// wiring. It stays out of the Tab order, which the list itself holds.
    private func line(_ kind: ResetKind) -> some View {
        let blocked = reason(kind)
        let isPicked = picked == kind.key
        return Button {
            guard blocked == nil else { return }
            picked = kind.key
            cursor = kind.key
        } label: {
            lineLabel(kind, blocked: blocked, isPicked: isPicked)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Self.accessibilityLabel(for: kind, reason: blocked, picked: isPicked))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func lineLabel(_ kind: ResetKind, blocked: String?, isPicked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isPicked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            (Text("\(kind.count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
             + Text("  \(kind.label)")
                .font(.system(size: 13)))
                .foregroundStyle(blocked == nil ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(kind.label)
            Spacer(minLength: 8)
            if let blocked {
                Text(blocked)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if focused, cursor == kind.key {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15))
            }
        }
        .contentShape(Rectangle())
    }

    /// `2 Full reset, picked`, or `1 <model> reset, unavailable: Paused`.
    static func accessibilityLabel(for kind: ResetKind, reason: String?, picked: Bool) -> String {
        var text = "\(kind.count) \(kind.label)"
        if let reason { text += ", unavailable: \(reason)" }
        if picked { text += ", picked" }
        return text
    }
}
