import Foundation
import CoreWLAN
import Observation
import OSLog
import Core

/// Read-only CoreWLAN wrapper for Phase 1. Reads:
///   - the configured (system-known) network profiles via `CWConfiguration.networkProfiles`
///   - nearby scan results via `CWInterface.scanForNetworks(withSSID:)`
///   - the current association via `CWInterface.ssid()`, `.bssid()`, `.rssiValue()`, etc.
///
/// CoreWLAN is not thread-safe, so all calls are serialized through this actor.
/// FOUND-04: known-network detection + scan intersect.
/// FOUND-05: uses CWWiFiClient + CWInterface — no `airport` CLI, no `SCNetworkReachability`.
public actor WiFiInspector {
    public enum InspectorError: Error, Sendable, LocalizedError {
        case noWiFiInterface
        case scanFailed(underlying: String)

        public var errorDescription: String? {
            switch self {
            case .noWiFiInterface:
                return "No Wi-Fi interface available on this Mac."
            case .scanFailed(let underlying):
                return "Wi-Fi scan failed: \(underlying)"
            }
        }
    }

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "WiFiInspector")
    private let client: CWWiFiClient

    public init(client: CWWiFiClient = .shared()) {
        self.client = client
    }

    /// Return the SSIDs the system has remembered, in the configured priority order.
    public func knownNetworks() throws -> [KnownNetwork] {
        guard let interface = client.interface() else {
            throw InspectorError.noWiFiInterface
        }
        let config = interface.configuration()
        guard let profiles = config?.networkProfiles.array as? [CWNetworkProfile] else {
            return []
        }
        return profiles.compactMap { profile in
            guard let ssid = profile.ssid else { return nil }
            return KnownNetwork(ssid: ssid, security: securityLabel(profile.security))
        }
    }

    /// Perform a fresh active scan and return everything the radio sees.
    /// Note: CoreWLAN active scans are expensive — Phase 2 introduces adaptive cadence.
    public func scanNearby() throws -> [ScanResult] {
        guard let interface = client.interface() else {
            throw InspectorError.noWiFiInterface
        }
        let networks: Set<CWNetwork>
        do {
            networks = try interface.scanForNetworks(withSSID: nil)
        } catch {
            log.error("scan failed: \(error.localizedDescription, privacy: .public)")
            throw InspectorError.scanFailed(underlying: error.localizedDescription)
        }
        let now = Date()
        let results = networks.map { network -> ScanResult in
            let channelNumber = network.wlanChannel?.channelNumber ?? 0
            let band: WiFiBand
            switch network.wlanChannel?.channelBand {
            case .band2GHz: band = .band2_4GHz
            case .band5GHz: band = .band5GHz
            case .band6GHz: band = .band6GHz
            case .bandUnknown, .none: band = WiFiBand.band(forChannel: channelNumber)
            @unknown default: band = .unknown
            }
            return ScanResult(
                ssid: network.ssid ?? "<hidden>",
                bssid: network.bssid,
                rssi: network.rssiValue,
                channel: channelNumber,
                band: band,
                observedAt: now
            )
        }
        return results.sorted { $0.rssi > $1.rssi }
    }

    /// Read the active connection's properties — what the user is on right now.
    public func currentAssociation() throws -> (ssid: String?, bssid: String?, rssi: Int?, channel: Int?, band: WiFiBand?) {
        guard let interface = client.interface() else {
            throw InspectorError.noWiFiInterface
        }
        let channelNumber = interface.wlanChannel()?.channelNumber
        let band: WiFiBand?
        if let raw = interface.wlanChannel()?.channelBand {
            switch raw {
            case .band2GHz: band = .band2_4GHz
            case .band5GHz: band = .band5GHz
            case .band6GHz: band = .band6GHz
            case .bandUnknown: band = channelNumber.map(WiFiBand.band(forChannel:))
            @unknown default: band = .unknown
            }
        } else {
            band = channelNumber.map(WiFiBand.band(forChannel:))
        }
        // rssiValue() returns 0 when not associated — translate to nil for the UI.
        let rssi = interface.rssiValue()
        return (
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: rssi == 0 ? nil : rssi,
            channel: channelNumber,
            band: band
        )
    }

    /// Take one full snapshot: current connection + scan + intersect against known networks.
    public func snapshot() throws -> WiFiSnapshot {
        let known = try knownNetworks()
        let knownSSIDs = Set(known.map(\.ssid))
        let scans = try scanNearby()
        let current = try currentAssociation()

        let allCandidates = scans.map { scan in
            Candidate(scan: scan, isKnown: knownSSIDs.contains(scan.ssid))
        }
        let knownCandidates = allCandidates.filter(\.isKnown)

        return WiFiSnapshot(
            currentSSID: current.ssid,
            currentBSSID: current.bssid,
            currentRSSI: current.rssi,
            currentChannel: current.channel,
            currentBand: current.band,
            knownInRange: knownCandidates,
            allInRange: allCandidates,
            capturedAt: Date()
        )
    }

    private func securityLabel(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        case .OWE: return "OWE"
        case .oweTransition: return "OWE Transition"
        case .unknown: return "?"
        @unknown default: return "?"
        }
    }
}
