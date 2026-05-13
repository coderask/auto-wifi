import Foundation

/// 2.4 GHz vs 5 GHz vs 6 GHz radio band. Same SSID on two bands is two distinct candidates,
/// because backhaul quality and interference profiles differ per band.
public enum WiFiBand: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case band2_4GHz = "2.4 GHz"
    case band5GHz = "5 GHz"
    case band6GHz = "6 GHz"
    case unknown = "?"

    /// Map a Wi-Fi channel number to its band. Channels 1-14 are 2.4 GHz; 32-177 are 5 GHz;
    /// 1-233 in 6 GHz overlap numerically with 2.4 GHz, so the band must be reported by the
    /// driver alongside the channel — but this fallback is correct for everything but 6 GHz.
    public static func band(forChannel channel: Int) -> WiFiBand {
        switch channel {
        case 1...14: return .band2_4GHz
        case 32...177: return .band5GHz
        default: return .unknown
        }
    }
}

/// A Wi-Fi network the user has previously saved to the system. Read from `CWConfiguration.networkProfiles`.
public struct KnownNetwork: Sendable, Hashable, Identifiable {
    public let ssid: String
    public let security: String

    public var id: String { ssid }

    public init(ssid: String, security: String) {
        self.ssid = ssid
        self.security = security
    }
}

/// A single scan observation of an in-range Wi-Fi network. Multiple `ScanResult`s can share
/// the same SSID — they're distinguished by BSSID (the AP's MAC).
public struct ScanResult: Sendable, Hashable, Identifiable {
    public let ssid: String
    /// BSSID is nil when Location Services authorization is missing — macOS redacts it.
    public let bssid: String?
    public let rssi: Int
    public let channel: Int
    public let band: WiFiBand
    public let observedAt: Date

    public var id: String {
        "\(ssid)|\(bssid ?? "?")|\(channel)"
    }

    public init(
        ssid: String,
        bssid: String?,
        rssi: Int,
        channel: Int,
        band: WiFiBand,
        observedAt: Date
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.channel = channel
        self.band = band
        self.observedAt = observedAt
    }
}

/// A scored switch candidate — a known network observed in range right now. Phases 3-4 will
/// extend this with smoothed RSSI, health metrics, and a composite score; Phase 1 just shows
/// the raw observation so the user can see CoreWLAN data is flowing.
public struct Candidate: Sendable, Hashable, Identifiable {
    public let scan: ScanResult
    public let isKnown: Bool

    public var id: String { scan.id }

    public init(scan: ScanResult, isKnown: Bool) {
        self.scan = scan
        self.isKnown = isKnown
    }
}

/// A single health measurement of the *currently associated* network. The Decision engine
/// combines this with smoothed RSSI to produce the composite score.
///
/// `latencyMillis`, `dnsSuccess`, and `captiveDetected` are the three primary signals;
/// `isExpensive` / `isConstrained` come straight from `NWPath` and let HEAL-04 (don't
/// probe over cellular tether) trigger upstream.
public struct HealthSample: Sendable, Hashable {
    public let latencyMillis: Double?
    public let dnsSuccess: Bool
    public let captiveDetected: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let isConnected: Bool
    public let measuredAt: Date

    public init(
        latencyMillis: Double?,
        dnsSuccess: Bool,
        captiveDetected: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isConnected: Bool,
        measuredAt: Date
    ) {
        self.latencyMillis = latencyMillis
        self.dnsSuccess = dnsSuccess
        self.captiveDetected = captiveDetected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isConnected = isConnected
        self.measuredAt = measuredAt
    }

    public static let pending = HealthSample(
        latencyMillis: nil,
        dnsSuccess: false,
        captiveDetected: false,
        isExpensive: false,
        isConstrained: false,
        isConnected: false,
        measuredAt: .distantPast
    )
}

/// SCAN-03: the canonical identity of a Wi-Fi observation is `(SSID, BSSID, band, channel)`.
/// Same SSID on 2.4 GHz vs 5 GHz is two distinct candidates because backhaul quality and
/// interference profiles differ per band; same SSID on different APs (different BSSIDs) is
/// also two distinct candidates because the physical AP matters.
public struct CandidateKey: Sendable, Hashable, Codable {
    public let ssid: String
    public let bssid: String?
    public let band: WiFiBand
    public let channel: Int

    public init(ssid: String, bssid: String?, band: WiFiBand, channel: Int) {
        self.ssid = ssid
        self.bssid = bssid
        self.band = band
        self.channel = channel
    }
}

extension ScanResult {
    public var candidateKey: CandidateKey {
        CandidateKey(ssid: ssid, bssid: bssid, band: band, channel: channel)
    }
}

/// A snapshot of "what's the WiFi situation right now?" — rendered into the main window.
public struct WiFiSnapshot: Sendable {
    public let currentSSID: String?
    public let currentBSSID: String?
    public let currentRSSI: Int?
    public let currentChannel: Int?
    public let currentBand: WiFiBand?
    public let knownInRange: [Candidate]
    public let allInRange: [Candidate]
    public let capturedAt: Date

    public init(
        currentSSID: String?,
        currentBSSID: String?,
        currentRSSI: Int?,
        currentChannel: Int?,
        currentBand: WiFiBand?,
        knownInRange: [Candidate],
        allInRange: [Candidate],
        capturedAt: Date
    ) {
        self.currentSSID = currentSSID
        self.currentBSSID = currentBSSID
        self.currentRSSI = currentRSSI
        self.currentChannel = currentChannel
        self.currentBand = currentBand
        self.knownInRange = knownInRange
        self.allInRange = allInRange
        self.capturedAt = capturedAt
    }

    public static let empty = WiFiSnapshot(
        currentSSID: nil,
        currentBSSID: nil,
        currentRSSI: nil,
        currentChannel: nil,
        currentBand: nil,
        knownInRange: [],
        allInRange: [],
        capturedAt: .distantPast
    )
}
