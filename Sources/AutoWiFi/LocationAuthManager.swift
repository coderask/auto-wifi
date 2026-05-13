import Foundation
import CoreLocation
import AppKit
import Observation
import OSLog

/// macOS gates SSID/BSSID visibility behind Location Services authorization (since macOS 11,
/// strictly enforced from 14.4+). Without authorization, every `CWNetwork.ssid` and
/// `.bssid` returns nil and the app appears broken. This manager owns the auth lifecycle
/// and publishes a state the UI can react to.
///
/// Implements FOUND-02 (request on first launch + explain why) and FOUND-03 (detect
/// revocation + show remediation banner with deep-link to Settings).
@MainActor
@Observable
public final class LocationAuthManager: NSObject, CLLocationManagerDelegate {
    public enum State: Sendable, Equatable {
        /// First launch — we haven't asked yet.
        case notDetermined
        /// User said yes. SSIDs/BSSIDs will resolve.
        case authorized
        /// User denied or revoked. SSIDs will return nil. Remediation banner shown.
        case denied
        /// MDM / Screen Time / parental controls disallow Location entirely.
        case restricted
    }

    public private(set) var state: State = .notDetermined

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "LocationAuth")
    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        // Read whatever the system already knows; the delegate callback fires shortly with
        // any change, but seeding this avoids a one-tick "unknown" flash on launch.
        updateStateFromAuthorizationStatus(manager.authorizationStatus)
    }

    /// Trigger the system permission prompt. Safe to call repeatedly — macOS only shows the
    /// dialog once per app install; later calls are no-ops if already determined.
    public func requestAuthorization() {
        log.info("requesting Location authorization (current=\(self.state.debugLabel, privacy: .public))")
        manager.requestAlwaysAuthorization()
        // Community-reported Sonoma+ quirk: SSID redaction sometimes persists until
        // `startUpdatingLocation()` has been called at least once after auth. Calling and
        // immediately stopping is enough to satisfy locationd.
        manager.startUpdatingLocation()
    }

    /// Open System Settings → Privacy & Security → Location Services. Used by the
    /// remediation banner when the user has revoked authorization.
    public func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.updateStateFromAuthorizationStatus(status)
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updateStateFromAuthorizationStatus(status)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't actually want location updates — we just needed startUpdatingLocation()
        // to fire once to satisfy locationd. Stop immediately to conserve power.
        Task { @MainActor in
            self.manager.stopUpdatingLocation()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location-data failures are irrelevant for our auth-only use; ignore.
        let label = error.localizedDescription
        Task { @MainActor [log] in
            log.debug("location update error (ignored): \(label, privacy: .public)")
        }
    }

    private func updateStateFromAuthorizationStatus(_ status: CLAuthorizationStatus) {
        let newState: State
        switch status {
        case .notDetermined:
            newState = .notDetermined
        case .authorizedAlways:
            newState = .authorized
        case .denied:
            newState = .denied
        case .restricted:
            newState = .restricted
        @unknown default:
            newState = .denied
        }
        if newState != state {
            log.info("auth state \(self.state.debugLabel, privacy: .public) → \(newState.debugLabel, privacy: .public)")
            state = newState
        }
    }
}

extension LocationAuthManager.State {
    var debugLabel: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        }
    }
}
