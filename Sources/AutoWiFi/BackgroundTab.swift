import SwiftUI

/// BG-01 + BG-02: Settings tab that toggles `SMAppService.mainApp` registration and
/// explains the "Background item added" notification *before* it appears. The screenshot
/// illustration helps the user recognize the system notification when it shows up.
struct BackgroundTab: View {
    @Environment(AppState.self) private var state
    @State private var showRegisterConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Background operation")
                    .font(.headline)

                Text("When enabled, auto-wifi runs in the background after login so it can monitor and switch networks while the main window is closed. Quit explicitly from the menubar to stop it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Status:")
                    Text(state.loginItem.status.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(state.loginItem.status.isEnabled ? .green : .secondary)
                    Spacer()
                    Button("Refresh") { state.loginItem.refresh() }
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    if state.loginItem.status.isEnabled {
                        Button(role: .destructive) {
                            state.loginItem.unregister()
                        } label: {
                            Label("Disable login item", systemImage: "power.circle.fill")
                        }
                    } else {
                        Button {
                            showRegisterConfirm = true
                        } label: {
                            Label("Enable login item…", systemImage: "power.circle")
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                    }
                    if state.loginItem.status == .requiresApproval {
                        Button("Open Login Items in Settings") {
                            state.loginItem.openLoginItemsSettings()
                        }
                    }
                }

                Divider()

                // BG-02: pre-emptive explanation of the macOS notification.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Heads-up: macOS will show a notification", systemImage: "bell.badge.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("After you click Enable, you'll see a system notification reading **\"Background Items Added\"** with the message **\"\"auto-wifi\"\" is an item that can run in the background.\"** This is normal and harmless. You can manage all background items at any time in System Settings → General → Login Items & Extensions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // A "screenshot" rendered with SF Symbols + native styling so we don't
                    // need to ship an image asset. Conveys the gist.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "gear.badge")
                                .imageScale(.large)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Background Items Added")
                                    .font(.callout.weight(.semibold))
                                Text("\"auto-wifi\" is an item that can run in the background.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("now")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        Text("(What the macOS notification looks like)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .confirmationDialog("Enable auto-wifi as a login item?", isPresented: $showRegisterConfirm) {
            Button("Enable") { state.loginItem.register() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("auto-wifi will start automatically after you log in. macOS will show a \"Background Items Added\" notification right after — that's expected.")
        }
    }
}
