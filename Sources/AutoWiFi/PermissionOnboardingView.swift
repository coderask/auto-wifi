import SwiftUI

/// FOUND-02: explain *why* before triggering the macOS Location prompt.
struct PermissionOnboardingView: View {
    @Environment(LocationAuthManager.self) private var auth
    @State private var clickCount = 0
    @State private var lastClickAt: Date?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(.tint)

            Text("Welcome to auto-wifi")
                .font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Text("auto-wifi keeps you on the best known Wi-Fi network in range — and explains every switch it makes.")
                    .font(.title3)
                    .multilineTextAlignment(.leading)

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location Services access is required")
                            .font(.headline)
                        Text("macOS gates the names of nearby Wi-Fi networks behind Location Services. Without it, auto-wifi cannot see which networks are around you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your location is never collected")
                            .font(.headline)
                        Text("auto-wifi never logs, transmits, or stores your geographic location. The permission unlocks Wi-Fi metadata only.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                }
            }
            .frame(maxWidth: 520)

            VStack(spacing: 10) {
                Button {
                    clickCount += 1
                    lastClickAt = Date()
                    auth.requestAuthorization()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    auth.openLocationSettings()
                } label: {
                    Text("Open System Settings instead")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }

            // Live diagnostic readout. If the system prompt isn't appearing on click,
            // these labels confirm whether the button is firing and whether the auth
            // state ever changes. Remove once Phase 1 is verified end-to-end.
            VStack(spacing: 4) {
                Text("auth state: \(auth.state.debugLabel) · clicks: \(clickCount)\(lastClickAt.map { " · last \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("If the macOS Location prompt does not appear, grant access manually in System Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
