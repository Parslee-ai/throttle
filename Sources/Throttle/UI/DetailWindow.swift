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
                        actions: panelActions
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
        .sheet(item: $model.activeLogin) { flow in
            LoginSheet(flow: flow) { model.activeLogin = nil }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model) { showingSettings = false }
        }
        .sheet(item: $importPicker) { picker in
            ImportPickerSheet(picker: picker, onImport: model.importAccount) { importPicker = nil }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) { model.remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Throttle forgets the login. Nothing changes at the provider.")
        }
    }

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
            remove: { pendingRemoval = $0 }
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
