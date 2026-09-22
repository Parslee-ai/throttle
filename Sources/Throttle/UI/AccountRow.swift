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
    private var dimmed: Bool {
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
        .overlay(alignment: .trailing) {
            actionsMenu
                .padding(.trailing, PopupMetrics.actionsTrailingPadding)
        }
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
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
                        .foregroundStyle(.tertiary)
                }
                stateLine
            }
            .padding(.leading, PopupMetrics.indexWidth)
        }
    }

    private static let nameFont = Font.system(size: 14, weight: .semibold, design: .monospaced)

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
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Saving the email itself means "no nickname".
        actions.rename(name == account.email ? "" : name)
        isRenaming = false
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
                columnLines(columns)
                if !laneWindows.isEmpty {
                    lanes
                }
            }
        }
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
                    ForEach(line) { column in
                        view(for: column)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for column: Column) -> some View {
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
            ResetCreditsColumn(count: count, dimmed: dimmed)
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
