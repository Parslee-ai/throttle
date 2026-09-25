import SwiftUI

/// What a row can ask its owner to do. Every closure acts on the row's own
/// account; the owner decides what that means.
struct AccountRowActions {
    var refresh: @MainActor () -> Void = {}
    var retryStatusCheck: @MainActor () -> Void = {}
    var reLogin: @MainActor () -> Void = {}
    var moveUp: @MainActor () -> Void = {}
    var moveDown: @MainActor () -> Void = {}
    /// Saves a new name. An empty string clears the nickname.
    var rename: @MainActor (String) -> Void = { _ in }
    var remove: @MainActor () -> Void = {}
    /// Asks for the reset confirmation. Nothing is spent until it is confirmed.
    var useReset: @MainActor () -> Void = {}
    var dismissResetNotice: @MainActor () -> Void = {}
}

/// One account in the detail window (ISC-117 through ISC-124): its number,
/// name, plan, and state on the left, then one fixed-width column per usage
/// window, then the actions button at the far right.
struct AccountRow: View {
    let account: Account
    /// 1-based position in the display order; the menu bar shows the same.
    let number: Int
    let cached: CachedStatus?
    let planLabel: String?
    let now: Date
    let isFirstInSection: Bool
    let isLastInSection: Bool
    var actions = AccountRowActions()
    /// A banked reset for this account is being spent.
    var isResetting = false
    /// The last reset's message for this row, if one is showing.
    var resetNotice: ResetNotice?

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showsLanes = false
    @State private var actionsHovered = false
    @FocusState private var nameFieldFocused: Bool

    private var windows: [UsageWindow] { Formatting.windows(of: cached) }

    /// Secondary lanes are shown in a disclosure after the primary windows (ISC-120).
    private var primaryWindows: [UsageWindow] { Formatting.popupOrder(windows) }
    private var laneWindows: [UsageWindow] { windows.filter(\.isLane) }

    /// Windows dim whenever they are not a current, successful reading.
    private var dimmed: Bool { Self.isDimmed(cached) }

    /// Whether a row with this status draws dimmed, which also greys its Use
    /// reset button: no reading, a stale one, or any state but ok.
    static func isDimmed(_ cached: CachedStatus?) -> Bool {
        guard let cached else { return true }
        if cached.isStale { return true }
        if case .ok = cached.status.state { return false }
        return true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            identity
                .frame(width: PopupMetrics.identityWidth, alignment: .leading)
            Spacer()
                .frame(width: PopupMetrics.identityGap)
            usage
                .frame(width: PopupMetrics.columnsLineWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, PopupMetrics.horizontalPadding)
        .padding(.vertical, PopupMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            // Sits `actionsTrailingPadding` in from the right edge, like the
            // window's other trailing controls. When the row is narrower (a
            // visible scroller takes its share) the trailing space shrinks
            // first, and the leading spacer's minimum keeps the button clear
            // of the last column, so it never covers a bar.
            HStack(spacing: 0) {
                Spacer(minLength: PopupMetrics.actionsLeading)
                actionsMenu
                Spacer(minLength: 0)
                    .frame(maxWidth: PopupMetrics.actionsTrailingPadding)
                    .layoutPriority(1)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
        // Like Finder: clicking away from the name field saves it.
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused, isRenaming { commitRename() }
        }
        .onDisappear {
            if isRenaming { commitRename() }
        }
    }

    // MARK: Identity column

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: PopupMetrics.indexWidth, alignment: .leading)
                    .accessibilityHidden(true)
                if isRenaming {
                    nameField
                } else {
                    nameLabel
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let plan = Formatting.planText(planLabel) {
                    Text(plan)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let cached, cached.isStale, cached.lastGoodWindows != nil {
                    Text(Formatting.agePhrase(since: cached.status.fetchedAt, now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(Colors.quietText)
                }
                stateLine
            }
            .padding(.leading, PopupMetrics.indexWidth)
        }
    }

    private static let nameFont = Font.system(size: 12, weight: .semibold, design: .monospaced)

    private var nameLabel: some View {
        Text(account.displayName)
            .font(Self.nameFont)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(account.email)
            .onTapGesture(count: 2) { beginRename() }
            .accessibilityLabel("\(number). \(account.displayName)")
    }

    private var nameField: some View {
        TextField(account.email, text: $draftName)
            .textFieldStyle(.plain)
            .font(Self.nameFont)
            .focused($nameFieldFocused)
            .onSubmit { commitRename() }
            // The field editor can swallow Escape before the exit command
            // reaches the view, so listen for the key as well.
            .onExitCommand { cancelRename() }
            .onKeyPress(.escape) {
                cancelRename()
                return .handled
            }
            .accessibilityLabel("Name for \(account.email)")
            .task {
                // The field appears as a menu closes; focus it once the
                // window has settled so typing lands here.
                try? await Task.sleep(for: .milliseconds(60))
                nameFieldFocused = true
            }
    }

    private func beginRename() {
        draftName = account.displayName
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unchanged name saves nothing; saving the email itself means
        // "no nickname".
        guard name != account.displayName else { return }
        actions.rename(name == account.email ? "" : name)
    }

    private func cancelRename() {
        isRenaming = false
        draftName = ""
    }

    @ViewBuilder
    private var stateLine: some View {
        if let cached {
            switch cached.status.state {
            case .ok:
                EmptyView()
            case .needsLogin:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sign in again", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("Log in again", action: actions.reLogin)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            case .rateLimited(let until):
                // A 429 from the provider's status endpoint, not the account's
                // own quota. Say so, or the user reads it as "my plan is out".
                Label("Status check throttled until \(Formatting.clockTime(until))", systemImage: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(account.provider.displayName) limits how often usage can be read. This is not your plan's quota; the next check runs at \(Formatting.clockTime(until)).")
                    .padding(.top, 2)
            case .forbidden(let reason):
                // The provider answers this for a token minted by its
                // API-console login page, which has no subscription usage to
                // read (D-34). The fix is a fresh sign-in through the
                // subscription page.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Wrong sign-in type", systemImage: "lock.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .help(reason + " This token came from the API-console page. Sign in again to use the \(account.provider.displayName) subscription page.")
                    Button("Sign in again", action: actions.reLogin)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Usage columns

    private enum Column: Identifiable {
        case window(UsageWindow)
        case resetCredits(Int)

        var id: String {
            switch self {
            case .window(let window): return window.key
            case .resetCredits: return "reset-credits"
            }
        }
    }

    private var columns: [Column] {
        var result = primaryWindows.map(Column.window)
        if let credits = cached?.status.resetCreditsAvailable {
            result.append(.resetCredits(credits))
        }
        return result
    }

    @ViewBuilder
    private var usage: some View {
        VStack(alignment: .leading, spacing: PopupMetrics.columnLineSpacing) {
            if cached == nil {
                Text("Waiting for first update…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    columnLines(columns)
                    if let notice = noticeBelowColumns {
                        ResetNoticeLine(notice: notice, onDismiss: actions.dismissResetNotice)
                            .frame(width: PopupMetrics.columnsLineWidth, alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: resetNotice)
                if !laneWindows.isEmpty {
                    lanes
                }
            }
        }
    }

    /// The resets column's place on its line of columns (0-based), when the
    /// row has one. It always comes after the windows.
    private var resetsSlot: Int? {
        guard let index = columns.firstIndex(where: { if case .resetCredits = $0 { true } else { false } }) else {
            return nil
        }
        return index % PopupMetrics.columnsPerLine
    }

    /// The message, when it does not fit on one line in the resets column's
    /// status line (the room to the end of its line of columns). It then
    /// takes a line of its own under the columns, the full width of a line,
    /// so it is never cut or squeezed into a narrow column.
    private var noticeBelowColumns: ResetNotice? {
        guard let notice = resetNotice, !isResetting, let slot = resetsSlot else { return nil }
        return Self.noticeGoesBelowColumns(notice.text, resetsSlot: slot) ? notice : nil
    }

    /// Whether a message for a resets column in `resetsSlot` is drawn on its
    /// own line under the columns rather than in the column.
    static func noticeGoesBelowColumns(_ text: String, resetsSlot: Int) -> Bool {
        !ResetCreditsColumn.noticeFitsOnOneLine(text, span: PopupMetrics.lineRemainder(fromSlot: resetsSlot))
    }

    /// Columns in lines of `PopupMetrics.columnsPerLine`, each the same fixed
    /// width, so extra windows wrap instead of shrinking.
    private func columnLines(_ items: [Column]) -> some View {
        let lines = stride(from: 0, to: items.count, by: PopupMetrics.columnsPerLine).map {
            Array(items[$0..<min($0 + PopupMetrics.columnsPerLine, items.count)])
        }
        return VStack(alignment: .leading, spacing: PopupMetrics.columnLineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: PopupMetrics.columnGap) {
                    ForEach(Array(line.enumerated()), id: \.element.id) { slot, column in
                        view(for: column, slot: slot)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for column: Column, slot: Int) -> some View {
        switch column {
        case .window(let window):
            WindowBar(
                window: window,
                providerName: account.provider.displayName,
                displayName: account.displayName,
                dimmed: dimmed,
                now: now
            )
        case .resetCredits(let count):
            ResetCreditsColumn(
                count: count,
                dimmed: dimmed,
                displayName: account.displayName,
                isResetting: isResetting,
                notice: noticeBelowColumns == nil ? resetNotice : nil,
                noticeSpan: PopupMetrics.lineRemainder(fromSlot: slot),
                onUse: actions.useReset,
                onDismissNotice: actions.dismissResetNotice
            )
        }
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsLanes.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsLanes ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("More lanes (\(laneWindows.count))")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsLanes ? "Hide more lanes" : "Show \(laneWindows.count) more lanes")
            if showsLanes {
                columnLines(laneWindows.map(Column.window))
            }
        }
    }

    // MARK: Actions

    /// The same actions as the context menu, behind a visible button, because
    /// right-click is not discoverable in a menu bar window.
    private var actionsMenu: some View {
        Menu {
            rowMenu
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .foregroundStyle(actionsHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { actionsHovered = $0 }
        .accessibilityLabel("Account actions for \(account.displayName)")
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("Refresh", action: actions.refresh)
        if case .rateLimited = cached?.status.state {
            Button("Retry status check now", action: actions.retryStatusCheck)
        }
        if let count = cached?.status.resetCreditsAvailable {
            Button("Use reset…", action: actions.useReset)
                .disabled(isResetting || ResetCreditsColumn.disabledReason(count: count, dimmed: dimmed) != nil)
        }
        Divider()
        Button("Rename…") { beginRename() }
        Divider()
        Button("Move up", action: actions.moveUp)
            .disabled(isFirstInSection)
        Button("Move down", action: actions.moveDown)
            .disabled(isLastInSection)
        Divider()
        switch cached?.status.state {
        case .needsLogin, .forbidden:
            Button("Sign in again", action: actions.reLogin)
        default:
            Button("Sign in again…", action: actions.reLogin)
        }
        Button("Remove…", role: .destructive, action: actions.remove)
    }
}
