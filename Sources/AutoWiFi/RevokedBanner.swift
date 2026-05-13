import SwiftUI

/// FOUND-03: non-blocking remediation banner with a one-click deep-link to Settings.
struct RevokedBanner: View {
    @Environment(LocationAuthManager.self) private var auth

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text("Location Services is off — Wi-Fi names will be hidden")
                    .font(.headline)
                Text(messageForState(auth.state))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings…") {
                auth.openLocationSettings()
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.yellow.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
    }

    private func messageForState(_ state: LocationAuthManager.State) -> String {
        switch state {
        case .denied:
            return "Enable Location Services for auto-wifi to see nearby Wi-Fi networks."
        case .restricted:
            return "Location Services is restricted by a system policy. auto-wifi cannot read Wi-Fi network names."
        default:
            return ""
        }
    }
}
