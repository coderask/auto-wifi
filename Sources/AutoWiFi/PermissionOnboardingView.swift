import SwiftUI

/// FOUND-02: explain *why* before sending the user to grant Location.
///
/// Ad-hoc-signed builds don't get the system prompt (macOS TCC silently suppresses it), so
/// instead of asking and hoping, we explicitly route the user to System Settings. We still
/// call `requestAuthorization()` because that registers the app's bundle ID with TCC, which
/// makes the app appear in the Location Services list — without it, the user would have
/// nothing to toggle on. Once notarized (v0.2+), TCC will show the system prompt directly
/// and this view can short-circuit on `auth.state == .authorized` before anyone sees it.
struct PermissionOnboardingView: View {
    @Environment(LocationAuthManager.self) private var auth
    @State private var didRequest = false

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

            if didRequest {
                // Second-state view: we've routed the user to Settings. Tell them what to do
                // there and let them re-open Settings if they accidentally dismissed the
                // window.
                VStack(spacing: 8) {
                    Label {
                        Text("System Settings should now be open.")
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "arrow.up.forward.app.fill").foregroundStyle(.tint)
                    }
                    Text("Find **auto-wifi** in the Location Services list and toggle it **on**. This window will continue automatically once you grant access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings again") {
                        auth.openLocationSettings()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 460)
            } else {
                Button {
                    didRequest = true
                    // Register the bundle ID with TCC (so the app appears in the list) and
                    // simultaneously open Settings so the user can find it.
                    auth.requestAuthorization()
                    auth.openLocationSettings()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Grant access in Settings")
                    }
                    .frame(maxWidth: 240)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            Text("Once auto-wifi is notarized (v0.2+), the standard macOS permission prompt will appear and this extra step will go away.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
