import SwiftUI

/// The `Add account` menu (ISC-123). One submenu per `Provider` case, built
/// by iterating `allCases` (ISC-41): the browser login, the paste-the-code
/// login where the provider supports it, and an import from the matching CLI
/// login where its source can exist.
///
/// An import reads another tool's login only when the user picks it
/// (ISC-137); the picker says when nothing was found. Whether the option is
/// listed is at most a file-existence check, decided by the provider registry.
struct AddAccountMenu: View {
    let model: AppModel
    @Binding var importPicker: ImportPicker?

    var body: some View {
        Menu {
            ForEach(Provider.allCases, id: \.self) { provider in
                Menu(provider.displayName) {
                    Button("Log in with browser") { model.addAccount(provider: provider, mode: .loopback) }
                    if let title = provider.manualCodeMenuTitle {
                        Button(title) { model.addAccount(provider: provider, mode: .manualCode) }
                    }
                    if let source = provider.importSourceName, model.importSourceExists(for: provider) {
                        Divider()
                        Button("Import from \(source)…") { present(provider) }
                    }
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
        provider.importSourceName ?? provider.displayName
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
