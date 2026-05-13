import SwiftUI

/// Top-level router: routes to the onboarding/permission screen when Location auth is
/// missing, and to the main inspector when it's granted. The revoked-after-grant state
/// shows the inspector with a non-blocking remediation banner on top.
struct RootView: View {
    @Environment(LocationAuthManager.self) private var auth

    var body: some View {
        switch auth.state {
        case .notDetermined:
            PermissionOnboardingView()
        case .denied, .restricted:
            VStack(spacing: 0) {
                RevokedBanner()
                InspectorView()
            }
        case .authorized:
            InspectorView()
        }
    }
}
