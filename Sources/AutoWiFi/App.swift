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
                    // Only start the long-running scanners once authorization is granted.
                    // Otherwise scan results return redacted SSIDs and everything looks broken.
                    if auth.state == .authorized {
                        await appState.start()
                    }
                }
                .onChange(of: auth.state) { _, newState in
                    if newState == .authorized {
                        Task { await appState.start() }
                    } else {
                        appState.stop()
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
