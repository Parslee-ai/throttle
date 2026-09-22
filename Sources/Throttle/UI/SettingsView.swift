import ServiceManagement
import SwiftUI

/// Preferences (ISC-126, ISC-127).
struct SettingsView: View {
    let model: AppModel
    let onDismiss: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Check usage every")
                    Spacer()
                    Text(pollIntervalText(settings.pollInterval))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: pollMinutes(settings: settings),
                    in: 1...30,
                    step: 1
                ) { editing in
                    if !editing { model.applySettings() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rotate menu bar every")
                    Spacer()
                    Text("\(Int(settings.rotationInterval)) s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $settings.rotationInterval,
                    in: AppSettings.rotationIntervalRange,
                    step: 1
                ) { editing in
                    if !editing { model.applySettings() }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLoginStatus == .enabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.launchAtLoginStatus == .requiresApproval {
                    Text("Approve Throttle under System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reveal diagnostics log") { model.revealDiagnosticsLog() }
                    .help("Shows the on-disk record of provider responses. It never contains a token.")
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { model.refreshLaunchAtLoginStatus() }
    }

    private func pollMinutes(settings: AppSettings) -> Binding<Double> {
        Binding(
            get: { (settings.pollInterval / 60).rounded() },
            set: { settings.pollInterval = $0 * 60 }
        )
    }

    private func pollIntervalText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}
