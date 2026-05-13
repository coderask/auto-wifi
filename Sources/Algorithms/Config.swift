import Foundation

/// DEC-04: every tunable constant lives here. Phase 6 surfaces these read-only in the UI;
/// v2 (TUNE-01) makes them editable. Loaded from JSON in the App Group at runtime — defaults
/// here are the starting calibration suggested by `research/SUMMARY.md`.
public struct AlgorithmConfig: Sendable, Equatable, Codable {
    // MARK: - EMA smoothing

    /// Exponential moving average factor. 0 = pure history (no update), 1 = pure latest sample.
    /// 0.3 weighs the latest sample at 30% — smooths out a single noisy RSSI dip without
    /// being so sticky that we ignore real degradation.
    public var emaAlpha: Double

    // MARK: - Threshold bands (RSSI, in dBm)

    /// Above this RSSI, the current connection is "good enough" — we don't even *consider*
    /// switching, regardless of what other candidates look like. Stops needless flapping
    /// when both networks are perfectly fine.
    public var goodEnoughRSSI: Int

    /// Below this smoothed RSSI, the current connection is "weak" — start the degrade dwell
    /// timer. If we stay below for `degradeDwell` seconds, we transition to the DEGRADED
    /// FSM state and start evaluating candidates.
    public var tooWeakRSSI: Int

    // MARK: - Dwell timers (seconds)

    /// Sustained degradation window. We don't switch on the first weak sample — we wait
    /// until we've been below `tooWeakRSSI` for this long, smoothed.
    public var degradeDwell: TimeInterval

    /// Candidate confirmation window. A candidate must look better than current for this
    /// long before we commit to a switch — prevents flapping on transient improvements.
    public var candidateDwell: TimeInterval

    /// After a switch, freeze decisions for this long so the new connection has time to
    /// settle (DHCP, DNS, captive probe, etc.) before we re-evaluate.
    public var postSwitchCooldown: TimeInterval

    // MARK: - Switch margin (composite score units)

    /// Candidate must score *at least* this much higher than the current connection to
    /// trigger a switch. With the 0-100 normalized RSSI in `ScoringEngine`, 15 corresponds
    /// to roughly 10 dB of RSSI improvement.
    public var switchMargin: Double

    // MARK: - Score weights and modifiers

    public var rssiWeight: Double
    public var healthWeight: Double
    public var bandBoost5GHz: Double
    public var bandBoost6GHz: Double
    public var preferBoost: Double
    public var avoidPenalty: Double
    public var captivePenalty: Double
    public var neverAutoJoinPenalty: Double

    // MARK: - Active-traffic awareness (Phase 5 uses this)

    /// When a live call / large transfer is detected, raise the switch margin by this
    /// multiplier so we don't interrupt active sessions for marginal gains.
    public var activeTrafficMarginMultiplier: Double

    public init(
        emaAlpha: Double = 0.3,
        goodEnoughRSSI: Int = -67,
        tooWeakRSSI: Int = -75,
        degradeDwell: TimeInterval = 10,
        candidateDwell: TimeInterval = 8,
        postSwitchCooldown: TimeInterval = 30,
        switchMargin: Double = 15,
        rssiWeight: Double = 1.0,
        healthWeight: Double = 0.5,
        bandBoost5GHz: Double = 5,
        bandBoost6GHz: Double = 8,
        preferBoost: Double = 20,
        avoidPenalty: Double = -30,
        captivePenalty: Double = -200,
        neverAutoJoinPenalty: Double = -1000,
        activeTrafficMarginMultiplier: Double = 2.0
    ) {
        self.emaAlpha = emaAlpha
        self.goodEnoughRSSI = goodEnoughRSSI
        self.tooWeakRSSI = tooWeakRSSI
        self.degradeDwell = degradeDwell
        self.candidateDwell = candidateDwell
        self.postSwitchCooldown = postSwitchCooldown
        self.switchMargin = switchMargin
        self.rssiWeight = rssiWeight
        self.healthWeight = healthWeight
        self.bandBoost5GHz = bandBoost5GHz
        self.bandBoost6GHz = bandBoost6GHz
        self.preferBoost = preferBoost
        self.avoidPenalty = avoidPenalty
        self.captivePenalty = captivePenalty
        self.neverAutoJoinPenalty = neverAutoJoinPenalty
        self.activeTrafficMarginMultiplier = activeTrafficMarginMultiplier
    }

    public static let `default` = AlgorithmConfig()
}

/// Per-network policy override. UI-05 lets the user prefer / avoid / never-auto-join a
/// specific SSID. Stored in the persistence layer (Phase 7) keyed by SSID.
public enum NetworkPreference: String, Sendable, Codable, Equatable {
    case prefer
    case neutral
    case avoid
    case neverAutoJoin
}
