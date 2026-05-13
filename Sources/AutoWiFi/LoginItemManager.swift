import Foundation
import ServiceManagement
import Observation
import OSLog

/// BG-01: register the main app as a login item so it runs in the background after login
/// without the main window being open.
///
/// `SMAppService.mainApp` is the modern, idempotent path for "this app should be a login
/// item." The app must be in `/Applications` for `.enabled` to stick — macOS won't grant
/// login-item status to apps run from arbitrary paths.
@MainActor
@Observable
public final class LoginItemManager {
    public enum Status: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown(Int)
        case error(String)

        public var label: String {
            switch self {
            case .notRegistered: "Not enabled"
            case .enabled: "Enabled (will start at login)"
            case .requiresApproval: "Requires approval in System Settings"
            case .notFound: "App not found (must be installed in /Applications)"
            case .unknown(let n): "Unknown status (\(n))"
            case .error(let m): "Error: \(m)"
            }
        }

        public var isEnabled: Bool { self == .enabled }
    }

    public private(set) var status: Status = .notRegistered
    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "LoginItemManager")
    private let service = SMAppService.mainApp

    public init() {
        refresh()
    }

    public func refresh() {
        let raw = service.status
        switch raw {
        case .notRegistered: status = .notRegistered
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .unknown(raw.rawValue)
        }
    }

    public func register() {
        do {
            // Only call register if not already enabled — repeated registrations on
            // macOS 14.4+ can trigger the "Background item added" notification multiple
            // times, which annoys users (Pitfall 6 from research).
            if status != .enabled {
                try service.register()
                log.info("SMAppService.mainApp registered")
            }
            refresh()
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
    }

    public func unregister() {
        do {
            try service.unregister()
            log.info("SMAppService.mainApp unregistered")
            refresh()
        } catch {
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
    }

    /// Open System Settings → General → Login Items. Used by the in-app explanation when
    /// the user needs to approve the background item manually.
    public func openLoginItemsSettings() {
        // macOS 13+ deep-link to Login Items pane.
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}

import AppKit  // for NSWorkspace
