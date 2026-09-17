import SwiftUI

/// The `Add account` menu (ISC-123). Each provider offers the browser login
/// and, where the source can exist, an import from the matching CLI login.
///
/// The Claude Code import reads another app's Keychain item, which macOS may
/// gate behind a prompt, so it runs only when the user picks it (ISC-137);
/// the option is always listed and the picker says when nothing was found.
/// The Codex option appears only when its `auth.json` exists, which is a
/// file-existence check that reads nothing.
struct AddAccountMenu: View {
    let model: AppModel
    @Binding var importPicker: ImportPicker?

    var body: some View {
        Menu {
            Menu("Claude") {
                Button("Log in with browser") { model.addAccount(provider: .anthropic, mode: .loopback) }
                Button("Paste code instead…") { model.addAccount(provider: .anthropic, mode: .manualCode) }
                Divider()
                Button("Import from Claude Code…") { present(.anthropic) }
            }
            Menu("Codex") {
                Button("Log in with browser") { model.addAccount(provider: .openai, mode: .loopback) }
                if model.codexLoginFileExists {
                    Divider()
                    Button("Import from Codex CLI…") { present(.openai) }
                }
            }
        } label: {
            Label("Add account", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func present(_ provider: Provider) {
        importPicker = ImportPicker(provider: provider, candidates: model.importCandidates(for: provider))
    }
}

/// What the import picker shows: the candidates found for one provider.
struct ImportPicker: Identifiable {
    let id = UUID()
    let provider: Provider
    let candidates: [ImportCandidate]

    var sourceName: String {
        switch provider {
        case .anthropic: return "Claude Code"
        case .openai: return "Codex CLI"
        }
    }
}

/// Lists the logins found in another tool and imports the one the user picks.
struct ImportPickerSheet: View {
    let picker: ImportPicker
    let onImport: (ImportCandidate) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from \(picker.sourceName)")
                .font(.headline)
            if picker.candidates.isEmpty {
                Text("No \(picker.sourceName) login was found on this Mac. Use “Log in with browser” instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This copies the login into Throttle’s own Keychain item. \(picker.sourceName) keeps working as before.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(picker.candidates.enumerated()), id: \.offset) { _, candidate in
                    HStack {
                        Image(systemName: candidate.provider.symbolName)
                        Text(candidate.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Import") {
                            onImport(candidate)
                            onDismiss()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(picker.candidates.isEmpty ? "Close" : "Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
