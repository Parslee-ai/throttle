import SwiftUI

/// The popup footer's update control. Everything it shows comes from
/// `UpdateController.state`; it knows nothing about where updates come from.
struct UpdateButton: View {
    let controller: UpdateController

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            checkButton

        case .checking:
            progress("Checking…")

        case .upToDate(let version):
            Text("Throttle \(version) is up to date")
                .font(.caption)
                .foregroundStyle(.secondary)
            checkButton

        case .available(let version):
            installButton(version)

        case .downloading:
            progress("Downloading…")

        case .verifying:
            progress("Verifying…")

        case .installing:
            progress("Installing…")
                .help("Enter an administrator password when macOS asks, to finish the update.")

        case .relaunching:
            progress("Relaunching…")

        case .cancelled:
            Text("Install cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
            installButton(nil)

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
                .help(message)
            Button("Try Again") { controller.retry() }
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") { controller.checkForUpdates() }
    }

    /// `version` is shown when known; after a cancel the label is just
    /// "Install" because the version is already on screen above it.
    private func installButton(_ version: String?) -> some View {
        Button(version.map { "Install \($0)" } ?? "Install") { controller.installUpdate() }
            .buttonStyle(.borderedProminent)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
