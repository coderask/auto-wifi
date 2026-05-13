import Foundation

/// Exponential moving average smoother. Used to take the edge off a single noisy RSSI dip
/// so the FSM doesn't immediately flip to DEGRADED on a momentary glitch.
///
/// `value_new = α · sample + (1 − α) · value_old`
///
/// `α = 0.3` (the default) means 30% weight on the latest sample, 70% on history — the
/// half-life of a step change is roughly `log(0.5) / log(1 - α) ≈ 2` samples, which is
/// short enough to react quickly but long enough to swallow a single bad reading.
public struct EMA: Sendable, Equatable {
    public let alpha: Double
    public private(set) var value: Double?
    public private(set) var sampleCount: Int

    public init(alpha: Double, initial: Double? = nil) {
        self.alpha = alpha
        self.value = initial
        self.sampleCount = initial == nil ? 0 : 1
    }

    /// Fold a new sample in. The first sample initializes the EMA directly (no smoothing on
    /// a single data point) — subsequent samples are blended with `alpha`.
    public mutating func update(_ sample: Double) {
        sampleCount += 1
        if let prev = value {
            value = alpha * sample + (1 - alpha) * prev
        } else {
            value = sample
        }
    }

    /// Reset the EMA to no samples. Called when a candidate disappears from the scan list
    /// for long enough that any accumulated smoothing is stale.
    public mutating func reset() {
        value = nil
        sampleCount = 0
    }
}
