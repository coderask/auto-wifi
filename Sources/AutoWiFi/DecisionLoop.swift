import Foundation
import Observation
import OSLog
import Core
import Algorithms

/// OBS-01: continuously consumes ScanCoordinator + HealthProbe state, runs the DecisionEngine,
/// and emits Decisions to OSLog and an in-memory ring buffer. In `.observe` mode (the default)
/// no switching code is invoked — the loop just observes and logs.
///
/// OBS-03: the state machine state is exposed via `state.fsm` so the menubar (Phase 6) and
/// InspectorView can show it.
///
/// Phase 5 wired in:
///   - GuardState for SW-02 (manual hold) + SW-03 (pause). When `guards.isHeld` is true the
///     effective mode is forced to `.observe` for the duration.
///   - TrafficWatcher for SW-04: feeds `engineState.activeTraffic` so the DecisionEngine
///     raises the switch margin by `activeTrafficMarginMultiplier`.
///   - SwitchActor for SW-01 + SW-05: when mode is `.on` and the engine returns `.switchTo`,
///     the loop hands off to SwitchActor and folds the SwitchAttempt result back into the
///     decision log.
@MainActor
@Observable
public final class DecisionLoop {
    public private(set) var mode: AutoSwitchMode = .observe
    public private(set) var engineState = DecisionState(fsm: .steady)
    public private(set) var lastDecision: Decision?
    public private(set) var lastSwitchAttempt: SwitchActor.SwitchAttempt?
    public private(set) var log: [Decision] = []
    public var config: AlgorithmConfig = .default

    /// Live `(SSID, BSSID)` of the previous tick. We use this to detect manual joins:
    /// a link change with no corresponding recent `SwitchActor` attempt is the user joining
    /// a network themselves (SW-02).
    private var previousSSID: String?

    private static let maxInMemoryLog = 500
    private let osLog = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "DecisionLoop")
    private let engine: DecisionEngine
    private let switchActor = SwitchActor()

    private weak var scan: ScanCoordinator?
    private weak var health: HealthProbe?
    private weak var captive: CaptiveProbe?
    private weak var guards: GuardState?
    private weak var traffic: TrafficWatcher?

    private var loopTask: Task<Void, Never>?
    private var inFlightSwitch: Task<Void, Never>?

    public init(config: AlgorithmConfig = .default) {
        self.config = config
        self.engine = DecisionEngine(config: config)
    }

    public func attach(scan: ScanCoordinator, health: HealthProbe, captive: CaptiveProbe, guards: GuardState, traffic: TrafficWatcher) {
        self.scan = scan
        self.health = health
        self.captive = captive
        self.guards = guards
        self.traffic = traffic
    }

    public func setMode(_ new: AutoSwitchMode) {
        guard new != mode else { return }
        osLog.info("mode \(self.mode.rawValue, privacy: .public) → \(new.rawValue, privacy: .public)")
        mode = new
    }

    public func start(interval: Duration = .seconds(2)) {
        guard loopTask == nil else { return }
        osLog.info("DecisionLoop starting (mode=\(self.mode.rawValue, privacy: .public))")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        inFlightSwitch?.cancel()
        inFlightSwitch = nil
    }

    /// One evaluation cycle: detect manual joins, fold traffic state in, run the engine,
    /// emit a Decision, and (if mode == .on and not held) hand off to SwitchActor.
    public func tickOnce() async {
        guard mode != .off else { return }
        guard let scan, let health, let captive, let guards, let traffic else { return }

        let snap = scan.snapshot
        let healthSample = health.lastSample
        let captiveFlags = await capturedCaptiveFlags(captive: captive, snapshot: snap)
        let currentKey: CandidateKey? = currentCandidateKey(from: snap)

        // Manual-join detection (SW-02): if the SSID changed since the previous tick AND
        // the SwitchActor hasn't completed a switch to the new SSID in the last few seconds,
        // a human joined a different network. Honor that choice for the next 10 minutes.
        await detectManualJoinIfNeeded(currentSSID: snap.currentSSID, guards: guards)
        previousSSID = snap.currentSSID

        // Active-traffic awareness (SW-04): the watcher updates on its own cadence; just
        // mirror its latest verdict into engineState before evaluation.
        engineState.activeTraffic = traffic.isActiveTraffic

        let inputs = DecisionInputs(
            candidates: snap.allInRange,
            currentKey: currentKey,
            currentRSSI: snap.currentRSSI,
            health: healthSample,
            preferences: [:],  // BG-04 (Phase 7) will populate this from SwiftData.
            captiveFlags: captiveFlags,
            now: Date()
        )

        let (newState, decision) = engine.evaluate(state: engineState, inputs: inputs)
        engineState = newState
        lastDecision = decision
        appendLog(decision)

        scan.setCadence(scanCadence(for: newState.fsm))

        switch decision.action {
        case .switchTo(let target):
            let effectiveMode = (guards.isHeld || inFlightSwitch != nil) ? AutoSwitchMode.observe : mode
            osLog.info("decision: switchTo \(target.ssid, privacy: .public) (mode=\(self.mode.rawValue, privacy: .public), effective=\(effectiveMode.rawValue, privacy: .public)\(guards.isHeld ? ", \(guards.holdReason ?? "held")" : "", privacy: .public))")
            if effectiveMode == .on {
                engine.markSwitchAttempted(state: &engineState, at: Date())
                executeSwitch(target: target)
            }
        case .stay, .stayCurrentGoodEnough, .rejectedSwitch, .rejectedSwitchCooldown, .noCurrentConnection:
            osLog.debug("decision: \(self.actionLabel(decision.action), privacy: .public) — \(decision.reason, privacy: .public)")
        }
    }

    // MARK: - Switch execution

    private func executeSwitch(target: CandidateKey) {
        guard inFlightSwitch == nil else { return }
        inFlightSwitch = Task { [weak self] in
            guard let self else { return }
            let attempt = await self.switchActor.associate(to: target)
            await MainActor.run {
                self.lastSwitchAttempt = attempt
                self.appendSwitchAttemptOutcome(attempt)
                self.inFlightSwitch = nil
            }
        }
    }

    private func appendSwitchAttemptOutcome(_ attempt: SwitchActor.SwitchAttempt) {
        // Synthesize a "post-switch outcome" Decision so the log reflects success/failure.
        // The DecisionEngine's `markSwitchAttempted` already started the cooldown; this is
        // purely a UI/log record.
        let reason: String
        if attempt.success == true {
            reason = "switch to '\(attempt.target.ssid)' succeeded"
        } else {
            reason = "switch to '\(attempt.target.ssid)' failed: \(attempt.errorMessage ?? "unknown")"
        }
        let outcome = Decision(
            timestamp: attempt.completedAt ?? Date(),
            action: attempt.success == true ? .switchTo(target: attempt.target) : .rejectedSwitch(target: attempt.target, dwellRemaining: nil, marginShortBy: nil),
            reason: reason,
            currentKey: lastDecision?.currentKey,
            currentScore: lastDecision?.currentScore,
            candidateScores: [],
            fsmStateAfter: engineState.fsm
        )
        appendLog(outcome)
    }

    // MARK: - Manual-join detection

    private func detectManualJoinIfNeeded(currentSSID: String?, guards: GuardState) async {
        guard let prev = previousSSID, let current = currentSSID, prev != current else { return }
        // Was SwitchActor responsible? Check its last completed attempt.
        let recentSwitch = await switchActor.lastAttempt
        let appInitiated: Bool = {
            guard let recent = recentSwitch, let completed = recent.completedAt else { return false }
            // If the most-recent switch completed in the last 20s and targeted this new SSID,
            // it was us, not the user.
            guard completed.timeIntervalSinceNow > -20 else { return false }
            return recent.target.ssid == current
        }()
        if !appInitiated {
            osLog.info("manual-join detected: \(prev, privacy: .public) → \(current, privacy: .public) — entering manual hold")
            guards.enterManualHold()
        }
    }

    // MARK: - Log filtering

    public enum Filter: Sendable, Equatable, CaseIterable, Identifiable {
        case all, switchesOnly, rejected, errors
        public var id: String { String(describing: self) }
        public var label: String {
            switch self {
            case .all: "All"
            case .switchesOnly: "Switches"
            case .rejected: "Rejected"
            case .errors: "Errors"
            }
        }
    }

    public func filteredLog(_ filter: Filter) -> [Decision] {
        switch filter {
        case .all: return log
        case .switchesOnly: return log.filter {
            if case .switchTo = $0.action { return true } else { return false }
        }
        case .rejected: return log.filter {
            switch $0.action {
            case .rejectedSwitch, .rejectedSwitchCooldown: return true
            default: return false
            }
        }
        case .errors: return log.filter { $0.reason.contains("failed:") }
        }
    }

    public func clearLog() {
        log.removeAll()
        lastDecision = nil
    }

    // MARK: - Internals

    private func appendLog(_ d: Decision) {
        log.append(d)
        if log.count > Self.maxInMemoryLog {
            log.removeFirst(log.count - Self.maxInMemoryLog)
        }
    }

    private func scanCadence(for fsm: DecisionState.FSM) -> ScanCoordinator.Cadence {
        switch fsm {
        case .off, .steady: .steady
        case .degraded, .switching: .degraded
        case .cooldown: .cooldown
        }
    }

    private func currentCandidateKey(from snap: WiFiSnapshot) -> CandidateKey? {
        guard let ssid = snap.currentSSID, let band = snap.currentBand else { return nil }
        return CandidateKey(ssid: ssid, bssid: snap.currentBSSID, band: band, channel: snap.currentChannel ?? 0)
    }

    private func capturedCaptiveFlags(captive: CaptiveProbe, snapshot: WiFiSnapshot) async -> [CandidateKey: Bool] {
        var result: [CandidateKey: Bool] = [:]
        let verdicts = await captive.verdicts
        for c in snapshot.allInRange {
            let key = CandidateKey(ssid: c.scan.ssid, bssid: c.scan.bssid, band: c.scan.band, channel: c.scan.channel)
            let captiveKey = CaptiveProbe.Key(ssid: c.scan.ssid, bssid: c.scan.bssid)
            if let v = verdicts[captiveKey] { result[key] = v.captive }
        }
        return result
    }

    private func actionLabel(_ a: Decision.Action) -> String {
        switch a {
        case .stay: "stay"
        case .stayCurrentGoodEnough: "stayCurrentGoodEnough"
        case .rejectedSwitch: "rejectedSwitch"
        case .rejectedSwitchCooldown: "rejectedSwitchCooldown"
        case .switchTo: "switchTo"
        case .noCurrentConnection: "noCurrentConnection"
        }
    }
}
