import SwiftUI
import AppKit

@main
struct AutoWiFiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Forces the app to a foreground (`.regular`) activation policy and brings it to the front
/// on launch. Without this, a hand-built `.app` bundle (no `.xcodeproj`, ad-hoc signed) often
/// launches with its window visible but the app inactive — meaning clicks land on
/// "activate the app" rather than on the button under the cursor. Two clicks would work;
/// the user reasonably expects one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Phase 1 has no menubar item yet (Phase 6), so closing the window should quit.
        // Phases 6+ will return false so the menubar surface keeps the app alive.
        true
    }
}
