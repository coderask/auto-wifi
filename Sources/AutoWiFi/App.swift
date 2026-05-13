import SwiftUI

@main
struct AutoWiFiApp: App {
    @State private var auth = LocationAuthManager()
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("auto-wifi") {
            RootView()
                .environment(auth)
                .environment(appState)
                .frame(minWidth: 720, minHeight: 540)
                .task {
                    // Phase 1: only poll once authorization is granted. Otherwise the
                    // first scan returns redacted SSIDs and the table looks broken.
                    if auth.state == .authorized {
                        appState.startPolling()
                    }
                }
                .onChange(of: auth.state) { _, newState in
                    if newState == .authorized {
                        appState.startPolling()
                        Task { await appState.refresh() }
                    } else {
                        appState.stopPolling()
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
