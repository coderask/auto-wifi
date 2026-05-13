import SwiftUI
import AppKit

@main
struct AutoWiFiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var auth = LocationAuthManager()
    @State private var appState = AppState()

    var body: some Scene {
        // MenuBarExtra is always present and is the primary surface (UI-01, UI-06).
        // The main window is opened on demand from the menu or appears automatically when
        // onboarding is needed.
        MenuBarExtra {
            MenuBarContent()
                .environment(auth)
                .environment(appState)
        } label: {
            MenuBarTitle()
                .environment(auth)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("auto-wifi", id: "main") {
            RootView()
                .environment(auth)
                .environment(appState)
                .frame(minWidth: 760, minHeight: 600)
                .task {
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

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

/// LSUIElement=true plus this delegate gives us: no Dock icon (the menubar item is the
/// primary surface), but the main window still comes up on first launch so onboarding works.
/// Without `.regular` policy here, system-modal dialogs (Location prompt, file pickers) can
/// fail to come to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force regular activation policy during launch so the onboarding window and
        // permission prompts come to the foreground. Phase 7 may switch to `.accessory`
        // post-auth for a more menubar-pure experience.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            // The first window in `NSApp.windows` may be the MenuBarExtra status item's
            // anchor window — find the regular main window and key it.
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // UI-06: closing the window must NOT quit the app — the menubar surface keeps it
        // running. User quits explicitly via the menubar.
        false
    }
}
