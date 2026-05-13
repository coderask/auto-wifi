import Foundation
import CoreWLAN
import OSLog
import Core

/// SW-01 + SW-05: drives `CWInterface.associate(toNetwork:password:)` to switch to a known
/// network, using credentials from the System Keychain (passing `nil` password tells CoreWLAN
/// to look up the saved credentials). Confirms the switch by polling for the new SSID with
/// a per-attempt timeout — failures are recorded as a `SwitchAttempt` and surfaced upstream
/// for the decision log.
///
/// `lastAttempt` is the single source of truth for "did we just try a switch?" — ManualJoin
/// detection compares the SSID-change timestamp against `lastAttempt.completedAt` to decide
/// whether a link change was app-initiated or user-initiated (SW-02).
public actor SwitchActor {
    public struct SwitchAttempt: Sendable {
        public let target: CandidateKey
        public let startedAt: Date
        public let completedAt: Date?
        public let success: Bool?
        public let errorMessage: String?
    }

    public private(set) var lastAttempt: SwitchAttempt?

    private let client: CWWiFiClient
    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "SwitchActor")
    private static let confirmationTimeout: TimeInterval = 15

    public init(client: CWWiFiClient = .shared()) {
        self.client = client
    }

    /// Attempt to switch to `target`. Returns the SwitchAttempt record so the caller can fold
    /// it into the decision log. The actor mutex serializes attempts so two parallel switch
    /// requests don't race CoreWLAN.
    public func associate(to target: CandidateKey) async -> SwitchAttempt {
        let startedAt = Date()
        log.info("associate start: ssid=\(target.ssid, privacy: .public) bssid=\(target.bssid ?? "?", privacy: .public)")

        let inFlight = SwitchAttempt(target: target, startedAt: startedAt, completedAt: nil, success: nil, errorMessage: nil)
        lastAttempt = inFlight

        guard let interface = client.interface() else {
            return finish(target: target, startedAt: startedAt, success: false, error: "no Wi-Fi interface")
        }

        let scanned: Set<CWNetwork>
        do {
            let ssidData = target.ssid.data(using: .utf8)
            scanned = try interface.scanForNetworks(withSSID: ssidData)
        } catch {
            return finish(target: target, startedAt: startedAt, success: false, error: "pre-associate scan failed: \(error.localizedDescription)")
        }

        let chosen = scanned.first(where: { $0.bssid == target.bssid }) ?? scanned.first(where: { $0.ssid == target.ssid })
        guard let network = chosen else {
            return finish(target: target, startedAt: startedAt, success: false, error: "target SSID not present in fresh scan")
        }

        do {
            try interface.associate(to: network, password: nil)
        } catch {
            return finish(target: target, startedAt: startedAt, success: false, error: "associate threw: \(error.localizedDescription)")
        }

        // Poll for confirmation. CoreWLAN doesn't give us a direct "associate finished"
        // callback; we observe that interface.ssid() matches our target.
        let deadline = Date().addingTimeInterval(Self.confirmationTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if let current = interface.ssid(), current == target.ssid {
                return finish(target: target, startedAt: startedAt, success: true, error: nil)
            }
        }
        return finish(target: target, startedAt: startedAt, success: false, error: "link-change confirmation timeout (\(Int(Self.confirmationTimeout))s)")
    }

    private func finish(target: CandidateKey, startedAt: Date, success: Bool, error: String?) -> SwitchAttempt {
        let attempt = SwitchAttempt(
            target: target,
            startedAt: startedAt,
            completedAt: Date(),
            success: success,
            errorMessage: error
        )
        lastAttempt = attempt
        if success {
            log.info("associate success: \(target.ssid, privacy: .public)")
        } else {
            log.error("associate failed: \(target.ssid, privacy: .public) — \(error ?? "?", privacy: .public)")
        }
        return attempt
    }
}
