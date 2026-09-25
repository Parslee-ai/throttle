import SwiftUI

/// The card shown while a login runs (ISC-58, 80, 121, 123), as a panel
/// modal over the detail window.
struct LoginSheet: View {
    @Bindable var flow: LoginFlow
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: flow.provider.symbolName)
                Text(flow.replacing == nil ? "Add \(flow.provider.displayName) account" : "Log in to \(flow.provider.displayName) again")
                    .font(.headline)
            }
            content
            HStack {
                if let url = flow.authorizeURL, flow.phase != .exchanging {
                    Button("Open browser again") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button(isFailed ? "Close" : "Cancel") {
                    flow.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                if flow.phase == .awaitingCode {
                    Button("Continue") { flow.submitCode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(flow.pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var isFailed: Bool {
        if case .failed = flow.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing sign-in…")
            }
        case .waitingForBrowser:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser…")
            }
            Text("Finish signing in to \(flow.provider.displayName) in your browser. This window updates on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .awaitingCode:
            Text("Sign in with your browser, then paste the code the page shows you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("CODE#STATE", text: $flow.pastedCode)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { flow.submitCode() }
        case .exchanging:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing sign-in…")
            }
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
        }
    }
}
