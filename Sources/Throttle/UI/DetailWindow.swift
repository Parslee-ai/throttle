import SwiftUI

/// The `MenuBarExtra` window: the header with the add-account menu, every
/// account grouped by provider, and the footer (ISC-117 through ISC-130).
/// `PopupMetrics.width` wide; the list scrolls once it would pass
/// `PopupMetrics.maxListHeight`.
///
/// The window paints its own adaptive background, so it follows the system's
/// light or dark setting like every color it draws with.
struct DetailWindow: View {
    @Bindable var model: AppModel

    @State private var pendingRemoval: Account?
    /// The account whose reset is waiting for the user's answer.
    @State private var pendingReset: Account?
    @State private var showingSettings = false
    @State private var importPicker: ImportPicker?

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            if model.accounts.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    AccountsPanel(
                        accounts: model.accounts,
                        statuses: model.statuses,
                        planLabels: planLabels,
                        now: context.date,
                        actions: panelActions,
                        resetsInFlight: model.resetsInFlight,
                        resetNotices: model.resetNotices
                    )
                }
            }
            divider
            footer
            if let error = model.lastError {
                divider
                errorBanner(error)
            }
        }
        .frame(width: PopupMetrics.width)
        .background(Colors.windowBackground)
        // Every question and form is a panel modal, drawn inside this
        // window. A sheet or dialog is a window of its own, and clicking in
        // it closes the menu bar panel (see `PanelModal`). Later modifiers
        // draw on top; a login is always on top.
        .panelModal(item: pendingRemoval) { account in
            ConfirmationCard(
                title: "Remove \(account.displayName)?",
                confirmTitle: "Remove",
                confirmRole: .destructive,
                onConfirm: {
                    pendingRemoval = nil
                    model.remove(account)
                },
                onCancel: { pendingRemoval = nil }
            ) {
                Text(Self.removalMessage)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelModal(item: pendingReset) { account in
            let cached = model.statuses[account.id]
            ResetConfirmation(
                displayName: account.displayName,
                count: cached?.status.resetCreditsAvailable ?? 0,
                windows: Formatting.popupOrder(Formatting.windows(of: cached)),
                onConfirm: {
                    pendingReset = nil
                    model.useReset(account)
                },
                onCancel: { pendingReset = nil }
            )
        }
        .panelModal(item: importPicker) { picker in
            ImportPickerSheet(picker: picker, onImport: model.importAccount) { importPicker = nil }
        }
        .panelModal(isPresented: showingSettings) {
            SettingsView(model: model) { showingSettings = false }
        }
        // The login lives on the model, not in this view: when the panel
        // closes while the user is in the browser, the flow keeps running,
        // and reopening the panel shows it again, or its result.
        .panelModal(item: model.activeLogin) { flow in
            LoginSheet(flow: flow) { model.activeLogin = nil }
        }
        // Under a card taller than the content, the panel grows; paint it.
        .background(Colors.windowBackground)
    }

    static let removalMessage = "Throttle forgets the login. Nothing changes at the provider."

    private var planLabels: [UUID: String] {
        var labels: [UUID: String] = [:]
        for account in model.accounts {
            if let plan = model.planLabel(for: account) { labels[account.id] = plan }
        }
        return labels
    }

    private var panelActions: AccountsPanelActions {
        let model = model
        return AccountsPanelActions(
            refresh: { model.refresh($0) },
            retryStatusCheck: { model.retryProvider(for: $0) },
            reLogin: { model.reLogin($0) },
            moveUp: { model.moveUp($0) },
            moveDown: { model.moveDown($0) },
            moveInSection: { model.move(in: $0, from: $1, to: $2) },
            rename: { model.rename($0, to: $1) },
            remove: { pendingRemoval = $0 },
            useReset: { account in
                // One confirmation at a time, and none while this row's reset runs.
                guard pendingReset == nil, !model.resetsInFlight.contains(account.id) else { return }
                pendingReset = account
            },
            dismissResetNotice: { model.dismissResetNotice(for: $0) }
        )
    }

    // MARK: Sections

    private var divider: some View {
        Rectangle()
            .fill(Colors.divider)
            .frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.secondary)
            Text("Throttle")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            AddAccountMenu(model: model, importPicker: $importPicker)
        }
        .padding(.horizontal, PopupMetrics.horizontalPadding)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No accounts yet")
                .font(.headline)
            Text("Use “Add account” to sign in to a Claude or Codex subscription. The menu bar rotates through every account you add.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(lastUpdatedText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            footerControls
        }
        .padding(.horizontal, PopupMetrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    /// The footer's trailing controls, in one row.
    private var footerControls: some View {
        HStack(spacing: 10) {
            UpdateButton(controller: model.updates)
            Button("Refresh all") { model.refreshAll() }
                .controlSize(.small)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .controlSize(.small)
                .help("Quit Throttle")
        }
    }

    private var lastUpdatedText: String {
        guard let date = model.lastUpdated else { return "Not updated yet" }
        return "Last updated \(Formatting.clockTimeWithSeconds(date))"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, PopupMetrics.horizontalPadding)
        .padding(.vertical, 8)
    }
}
