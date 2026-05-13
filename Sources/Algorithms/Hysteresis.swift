import Foundation
import Core

/// DEC-03: multi-layer hysteresis to prevent flapping. The decision pipeline is:
///
///   1. **EMA smoothing** — fold each per-BSSID RSSI sample into a per-key EMA so a single
///      noisy reading doesn't move the score.
///   2. **Threshold bands** — `goodEnoughRSSI` (above which we don't even consider switching)
///      and `tooWeakRSSI` (below which we mark current degraded). The gap between the two
///      values is the asymmetric hysteresis band.
///   3. **Dwell timers** — `degradeDwell` requires sustained weakness before we enter the
///      DEGRADED state; `candidateDwell` requires a candidate to *stay* meaningfully better
///      for a continuous window before we commit.
///   4. **Switch margin** — even after dwell, the candidate must score at least
///      `switchMargin` higher than current (a healthy margin that swallows noise).
///   5. **Post-switch cooldown** — after switching, we freeze decisions for
///      `postSwitchCooldown` seconds so the new connection has time to settle.
///
/// Together these five layers make flapping structurally impossible without simultaneous,
/// sustained, large-magnitude deltas — which is the actual signal we want to react to.

public struct DecisionState: Sendable, Equatable {
    public enum FSM: String, Sendable, Codable, Equatable {
        case off
        case steady
        case degraded
        case switching
        case cooldown
    }

    public var fsm: FSM
    public var emas: [CandidateKey: EMA]
    public var currentKey: CandidateKey?
    public var currentWeakSince: Date?
    public var candidateGoodSince: [CandidateKey: Date]
    public var lastSwitchAt: Date?
    /// Active-traffic flag — Phase 5 watcher writes this in. Raises the switch margin while
    /// the user is on a call / large transfer (SW-04).
    public var activeTraffic: Bool

    public init(
        fsm: FSM = .steady,
        emas: [CandidateKey: EMA] = [:],
        currentKey: CandidateKey? = nil,
        currentWeakSince: Date? = nil,
        candidateGoodSince: [CandidateKey: Date] = [:],
        lastSwitchAt: Date? = nil,
        activeTraffic: Bool = false
    ) {
        self.fsm = fsm
        self.emas = emas
        self.currentKey = currentKey
        self.currentWeakSince = currentWeakSince
        self.candidateGoodSince = candidateGoodSince
        self.lastSwitchAt = lastSwitchAt
        self.activeTraffic = activeTraffic
    }
}

public struct DecisionInputs: Sendable {
    public let candidates: [Candidate]
    public let currentKey: CandidateKey?
    public let currentRSSI: Int?
    public let health: HealthSample
    public let preferences: [String: NetworkPreference]
    public let captiveFlags: [CandidateKey: Bool]
    public let now: Date

    public init(
        candidates: [Candidate],
        currentKey: CandidateKey?,
        currentRSSI: Int?,
        health: HealthSample,
        preferences: [String: NetworkPreference] = [:],
        captiveFlags: [CandidateKey: Bool] = [:],
        now: Date
    ) {
        self.candidates = candidates
        self.currentKey = currentKey
        self.currentRSSI = currentRSSI
        self.health = health
        self.preferences = preferences
        self.captiveFlags = captiveFlags
        self.now = now
    }
}

/// DEC-05: every evaluation produces one of these, including for cycles where we stay.
/// Rejection records (`.rejectedSwitch`) explain *which* candidate was considered and *why*
/// it wasn't selected — the decision log surfaces these to make the algorithm's reasoning
/// visible.
public struct Decision: Sendable, Identifiable, Equatable {
    public enum Action: Sendable, Equatable {
        case stay
        case stayCurrentGoodEnough
        case rejectedSwitch(target: CandidateKey, dwellRemaining: TimeInterval?, marginShortBy: Double?)
        case rejectedSwitchCooldown(remaining: TimeInterval)
        case switchTo(target: CandidateKey)
        case noCurrentConnection
    }

    public let id: UUID
    public let timestamp: Date
    public let action: Action
    public let reason: String
    public let currentKey: CandidateKey?
    public let currentScore: ScoreBreakdown?
    public let candidateScores: [(key: CandidateKey, score: ScoreBreakdown)]
    public let fsmStateAfter: DecisionState.FSM

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        action: Action,
        reason: String,
        currentKey: CandidateKey?,
        currentScore: ScoreBreakdown?,
        candidateScores: [(key: CandidateKey, score: ScoreBreakdown)],
        fsmStateAfter: DecisionState.FSM
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.reason = reason
        self.currentKey = currentKey
        self.currentScore = currentScore
        self.candidateScores = candidateScores
        self.fsmStateAfter = fsmStateAfter
    }

    public static func == (lhs: Decision, rhs: Decision) -> Bool {
        lhs.id == rhs.id &&
        lhs.timestamp == rhs.timestamp &&
        lhs.action == rhs.action &&
        lhs.reason == rhs.reason &&
        lhs.currentKey == rhs.currentKey &&
        lhs.fsmStateAfter == rhs.fsmStateAfter
    }
}

public struct DecisionEngine: Sendable {
    public let config: AlgorithmConfig
    private let scoring: ScoringEngine

    public init(config: AlgorithmConfig = .default) {
        self.config = config
        self.scoring = ScoringEngine(config: config)
    }

    /// Pure function from `(state, inputs) -> (state', decision)`. State carries EMAs and
    /// dwell timers across calls; it has no relation to wall-clock time except via
    /// `inputs.now` (which the tests pass synthetically).
    public func evaluate(state: DecisionState, inputs: DecisionInputs) -> (DecisionState, Decision) {
        var newState = state
        let now = inputs.now

        // 1. Update EMAs for every observed candidate.
        for c in inputs.candidates {
            var ema = newState.emas[c.scan.candidateKey] ?? EMA(alpha: config.emaAlpha)
            ema.update(Double(c.scan.rssi))
            newState.emas[c.scan.candidateKey] = ema
        }
        // Reset EMAs for known networks no longer in scan (give them a chance to come back).
        let observedKeys = Set(inputs.candidates.map { $0.scan.candidateKey })
        for key in newState.emas.keys where !observedKeys.contains(key) {
            newState.emas[key]?.reset()
        }

        // 2. Score every known-in-range candidate (only known networks are switch targets).
        let knownCandidates = inputs.candidates.filter { $0.isKnown }
        var scores: [(key: CandidateKey, score: ScoreBreakdown)] = []
        for c in knownCandidates {
            let key = c.scan.candidateKey
            let smoothed = newState.emas[key]?.value ?? Double(c.scan.rssi)
            let pref = inputs.preferences[key.ssid] ?? .neutral
            let isCaptive = inputs.captiveFlags[key] ?? false
            let isCurrent = key == inputs.currentKey
            let score = scoring.score(
                CandidateInputs(key: key, smoothedRSSI: smoothed, isCurrent: isCurrent, isCaptive: isCaptive, userPref: pref),
                health: isCurrent ? inputs.health : nil
            )
            scores.append((key: key, score: score))
        }
        scores.sort { $0.score.total > $1.score.total }

        // 3. Identify current connection's score (if it's a known network — could be
        // disconnected or on an unknown network).
        let currentKey = inputs.currentKey
        newState.currentKey = currentKey
        let currentScore = scores.first(where: { $0.key == currentKey })?.score

        // 4. Cooldown check: if we recently switched, refuse all switches until cooldown
        // expires regardless of how attractive the alternatives look.
        if let last = state.lastSwitchAt, now.timeIntervalSince(last) < config.postSwitchCooldown {
            let remaining = config.postSwitchCooldown - now.timeIntervalSince(last)
            newState.fsm = .cooldown
            let reason = "post-switch cooldown: \(formatSeconds(remaining)) remaining"
            return (newState, decisionStay(.rejectedSwitchCooldown(remaining: remaining), reason: reason, currentKey: currentKey, currentScore: currentScore, scores: scores, fsm: newState.fsm, now: now))
        }

        // 5. No current connection: if there's a candidate, we'd normally want to switch
        // to the best one — but Phase 4 ships observe-only, so we only describe.
        guard let currentKey else {
            if let best = scores.first {
                newState.fsm = .switching
                newState.candidateGoodSince[best.key] = state.candidateGoodSince[best.key] ?? now
                return (newState, Decision(
                    timestamp: now,
                    action: .switchTo(target: best.key),
                    reason: "not connected to any known network; joining best candidate '\(best.key.ssid)' (score \(formatScore(best.score.total)))",
                    currentKey: nil,
                    currentScore: nil,
                    candidateScores: scores,
                    fsmStateAfter: .switching
                ))
            } else {
                newState.fsm = .steady
                return (newState, decisionStay(.noCurrentConnection, reason: "not connected; no known networks in range to join", currentKey: nil, currentScore: nil, scores: scores, fsm: .steady, now: now))
            }
        }

        // 6. Above the "good enough" band → STEADY, don't even consider switching.
        let currentSmoothed = newState.emas[currentKey]?.value ?? Double(inputs.currentRSSI ?? -100)
        if currentSmoothed >= Double(config.goodEnoughRSSI) {
            newState.fsm = .steady
            newState.currentWeakSince = nil
            newState.candidateGoodSince.removeAll()
            let reason = "current '\(currentKey.ssid)' at \(formatRSSI(currentSmoothed)) is above good-enough threshold (\(config.goodEnoughRSSI) dBm); not considering switch"
            return (newState, decisionStay(.stayCurrentGoodEnough, reason: reason, currentKey: currentKey, currentScore: currentScore, scores: scores, fsm: .steady, now: now))
        }

        // 7. Below the "too weak" band → start / continue the degrade dwell timer.
        if currentSmoothed < Double(config.tooWeakRSSI) {
            if newState.currentWeakSince == nil {
                newState.currentWeakSince = now
            }
            let weakFor = now.timeIntervalSince(newState.currentWeakSince ?? now)
            if weakFor < config.degradeDwell {
                newState.fsm = .degraded
                let remaining = config.degradeDwell - weakFor
                let reason = "current '\(currentKey.ssid)' weak at \(formatRSSI(currentSmoothed)) dBm but only for \(formatSeconds(weakFor)) — need \(formatSeconds(remaining)) more before considering switch"
                return (newState, decisionStay(.stay, reason: reason, currentKey: currentKey, currentScore: currentScore, scores: scores, fsm: .degraded, now: now))
            }
            newState.fsm = .degraded
        } else {
            // Within the hysteresis band (between tooWeakRSSI and goodEnoughRSSI). Don't
            // consider switching but also don't reset the dwell — we're in the gray zone.
            newState.fsm = .steady
            newState.currentWeakSince = nil
            let reason = "current '\(currentKey.ssid)' at \(formatRSSI(currentSmoothed)) dBm is within hysteresis band; not switching"
            return (newState, decisionStay(.stay, reason: reason, currentKey: currentKey, currentScore: currentScore, scores: scores, fsm: .steady, now: now))
        }

        // 8. Find the best candidate that is NOT the current connection.
        guard let bestAlternative = scores.first(where: { $0.key != currentKey }) else {
            newState.candidateGoodSince.removeAll()
            let reason = "current '\(currentKey.ssid)' degraded but no alternative known networks in range"
            return (newState, decisionStay(.stay, reason: reason, currentKey: currentKey, currentScore: currentScore, scores: scores, fsm: .degraded, now: now))
        }

        // 9. Switch margin check (with active-traffic multiplier).
        let currentTotal = currentScore?.total ?? -1_000_000
        let margin = bestAlternative.score.total - currentTotal
        let effectiveMargin = state.activeTraffic ? config.switchMargin * config.activeTrafficMarginMultiplier : config.switchMargin
        if margin < effectiveMargin {
            newState.candidateGoodSince.removeAll()
            let shortBy = effectiveMargin - margin
            let reason = "candidate '\(bestAlternative.key.ssid)' only \(formatScore(margin)) points better than current (need \(formatScore(effectiveMargin))\(state.activeTraffic ? ", raised due to active traffic" : "")); short by \(formatScore(shortBy))"
            return (newState, Decision(
                timestamp: now,
                action: .rejectedSwitch(target: bestAlternative.key, dwellRemaining: nil, marginShortBy: shortBy),
                reason: reason,
                currentKey: currentKey,
                currentScore: currentScore,
                candidateScores: scores,
                fsmStateAfter: .degraded
            ))
        }

        // 10. Candidate dwell — best candidate must look better for `candidateDwell` seconds.
        let goodSince = newState.candidateGoodSince[bestAlternative.key] ?? now
        newState.candidateGoodSince[bestAlternative.key] = goodSince
        // Forget other candidates' dwells — they're not the front-runner anymore.
        for key in newState.candidateGoodSince.keys where key != bestAlternative.key {
            newState.candidateGoodSince[key] = nil
        }
        let dwellElapsed = now.timeIntervalSince(goodSince)
        if dwellElapsed < config.candidateDwell {
            let dwellRemaining = config.candidateDwell - dwellElapsed
            let reason = "candidate '\(bestAlternative.key.ssid)' is \(formatScore(margin)) points better but has only been ahead for \(formatSeconds(dwellElapsed)); need \(formatSeconds(dwellRemaining)) more"
            return (newState, Decision(
                timestamp: now,
                action: .rejectedSwitch(target: bestAlternative.key, dwellRemaining: dwellRemaining, marginShortBy: nil),
                reason: reason,
                currentKey: currentKey,
                currentScore: currentScore,
                candidateScores: scores,
                fsmStateAfter: .degraded
            ))
        }

        // 11. All gates passed — recommend the switch.
        newState.fsm = .switching
        let reason = "switching: '\(bestAlternative.key.ssid)' (\(formatScore(bestAlternative.score.total))) sustained \(formatScore(margin))-point advantage over '\(currentKey.ssid)' (\(formatScore(currentTotal))) for \(formatSeconds(dwellElapsed))"
        return (newState, Decision(
            timestamp: now,
            action: .switchTo(target: bestAlternative.key),
            reason: reason,
            currentKey: currentKey,
            currentScore: currentScore,
            candidateScores: scores,
            fsmStateAfter: .switching
        ))
    }

    /// Called by the live driver after a switch attempt completes (success or failure) so
    /// the cooldown timer can start from now.
    public func markSwitchAttempted(state: inout DecisionState, at: Date) {
        state.lastSwitchAt = at
        state.candidateGoodSince.removeAll()
        state.currentWeakSince = nil
        state.fsm = .cooldown
    }

    private func decisionStay(
        _ action: Decision.Action,
        reason: String,
        currentKey: CandidateKey?,
        currentScore: ScoreBreakdown?,
        scores: [(key: CandidateKey, score: ScoreBreakdown)],
        fsm: DecisionState.FSM,
        now: Date
    ) -> Decision {
        Decision(
            timestamp: now,
            action: action,
            reason: reason,
            currentKey: currentKey,
            currentScore: currentScore,
            candidateScores: scores,
            fsmStateAfter: fsm
        )
    }
}

// MARK: - Formatting helpers (internal)

@inline(__always)
internal func formatRSSI(_ value: Double) -> String {
    String(format: "%.1f", value)
}

@inline(__always)
internal func formatScore(_ value: Double) -> String {
    String(format: "%+.1f", value)
}

@inline(__always)
internal func formatSeconds(_ value: TimeInterval) -> String {
    if value < 60 { return String(format: "%.0fs", value) }
    return String(format: "%.1fm", value / 60)
}
