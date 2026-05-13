import Foundation
import Core

/// DEC-02: composite score combining smoothed RSSI, measured health (current network only),
/// captive flag, band preference, and per-network user preference. Higher = better.
///
/// The score is intentionally additive and unbounded — `total` can range from very negative
/// (captive + never-auto-join) to ~125 (great RSSI + healthy + 5/6 GHz + preferred).
/// Hysteresis uses `switchMargin` (default 15) to decide what counts as "meaningfully better."
public struct ScoreBreakdown: Sendable, Equatable {
    public let total: Double
    public let rssiComponent: Double
    public let healthComponent: Double
    public let bandComponent: Double
    public let prefComponent: Double
    public let captivePenalty: Double

    public init(
        total: Double,
        rssiComponent: Double,
        healthComponent: Double,
        bandComponent: Double,
        prefComponent: Double,
        captivePenalty: Double
    ) {
        self.total = total
        self.rssiComponent = rssiComponent
        self.healthComponent = healthComponent
        self.bandComponent = bandComponent
        self.prefComponent = prefComponent
        self.captivePenalty = captivePenalty
    }
}

public struct CandidateInputs: Sendable {
    public let key: CandidateKey
    public let smoothedRSSI: Double
    public let isCurrent: Bool
    public let isCaptive: Bool
    public let userPref: NetworkPreference

    public init(
        key: CandidateKey,
        smoothedRSSI: Double,
        isCurrent: Bool,
        isCaptive: Bool,
        userPref: NetworkPreference
    ) {
        self.key = key
        self.smoothedRSSI = smoothedRSSI
        self.isCurrent = isCurrent
        self.isCaptive = isCaptive
        self.userPref = userPref
    }
}

public struct ScoringEngine: Sendable {
    public let config: AlgorithmConfig

    public init(config: AlgorithmConfig) {
        self.config = config
    }

    /// Score one candidate. For the currently-connected network, pass `health` so the health
    /// component contributes; for other candidates `health = nil` (we have no measurement).
    public func score(_ inputs: CandidateInputs, health: HealthSample? = nil) -> ScoreBreakdown {
        let rssiComponent = rssiScore(inputs.smoothedRSSI) * config.rssiWeight
        let healthComponent = inputs.isCurrent ? healthScore(health) * config.healthWeight : 0
        let bandComponent: Double = {
            switch inputs.key.band {
            case .band5GHz: return config.bandBoost5GHz
            case .band6GHz: return config.bandBoost6GHz
            case .band2_4GHz, .unknown: return 0
            }
        }()
        let prefComponent: Double = {
            switch inputs.userPref {
            case .prefer: return config.preferBoost
            case .neutral: return 0
            case .avoid: return config.avoidPenalty
            case .neverAutoJoin: return config.neverAutoJoinPenalty
            }
        }()
        // HEAL-03: captive networks get a large negative modifier so the engine will not
        // recommend switching to them. Combined with neverAutoJoinPenalty for a network the
        // user also marked never-auto-join, this is fully disqualifying.
        let capPenalty = inputs.isCaptive ? config.captivePenalty : 0

        let total = rssiComponent + healthComponent + bandComponent + prefComponent + capPenalty
        return ScoreBreakdown(
            total: total,
            rssiComponent: rssiComponent,
            healthComponent: healthComponent,
            bandComponent: bandComponent,
            prefComponent: prefComponent,
            captivePenalty: capPenalty
        )
    }

    /// Map RSSI to a 0–100 scale where -30 dBm (saturating signal) → 100 and -100 dBm
    /// (effectively no signal) → 0. Linear in dB, which is roughly logarithmic in power —
    /// matches how humans perceive signal quality.
    private func rssiScore(_ rssi: Double) -> Double {
        let clamped = max(-100, min(-30, rssi))
        return (clamped + 100) * (100.0 / 70.0)
    }

    /// Health component from latency + DNS. 0-100 scale.
    /// - Latency: <50ms = 50pts, 50-150 = 35, 150-400 = 15, >400 or nil = 0
    /// - DNS success: 50pts if OK, 0 if down
    private func healthScore(_ sample: HealthSample?) -> Double {
        guard let s = sample, s.isConnected else { return 0 }
        let latencyPts: Double
        if let ms = s.latencyMillis {
            switch ms {
            case ..<50: latencyPts = 50
            case ..<150: latencyPts = 35
            case ..<400: latencyPts = 15
            default: latencyPts = 0
            }
        } else {
            latencyPts = 0
        }
        let dnsPts: Double = s.dnsSuccess ? 50 : 0
        return latencyPts + dnsPts
    }
}
