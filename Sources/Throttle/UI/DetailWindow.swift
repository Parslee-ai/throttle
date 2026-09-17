import SwiftUI

/// The `MenuBarExtra` window: every account as a row, the add-account menu,
/// and the footer (ISC-117 through ISC-130). 480 pt wide; the list scrolls
/// once the window would pass 720 pt.
struct DetailWindow: View {
    @Bindable var model: AppModel

    static let width: CGFloat = 480
    static let maxListHeight: CGFloat = 600

    @State private var pendingRemoval: Account?
    @State private var showingSettings = false
    @State private var importPicker: ImportPicker?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
            Divider()
            footer
            if let error = model.lastError {
                Divider()
                errorBanner(error)
            }
            Divider()
            Button("Quit Throttle") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
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
            "Remove \(pendingRemoval?.email ?? "this account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) { model.remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Throttle forgets the login. Nothing changes at the provider.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text("Throttle")
                .font(.headline)
            Spacer()
            AddAccountMenu(model: model, importPicker: $importPicker)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var accountList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.accounts) { account in
                        AccountRow(
                            account: account,
                            cached: model.statuses[account.id],
                            planLabel: model.planLabel(for: account),
                            showRemaining: model.settings.showRemaining,
                            now: context.date,
                            onReLogin: { model.reLogin(account) }
                        )
                        .contextMenu { rowMenu(for: account) }
                        Divider().padding(.leading, 12)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                })
            }
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            .frame(height: min(max(listHeight, 1), Self.maxListHeight))
        }
    }

    @ViewBuilder
    private func rowMenu(for account: Account) -> some View {
        Button("Refresh") { model.refresh(account) }
        Divider()
        Button("Move up") { model.moveUp(account) }
            .disabled(model.accounts.first?.id == account.id)
        Button("Move down") { model.moveDown(account) }
            .disabled(model.accounts.last?.id == account.id)
        Divider()
        if case .needsLogin = model.statuses[account.id]?.status.state {
            Button("Log in again") { model.reLogin(account) }
        } else {
            Button("Log in again…") { model.reLogin(account) }
        }
        Button("Remove…", role: .destructive) { pendingRemoval = account }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(lastUpdatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                .font(.caption)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
