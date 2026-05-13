import Foundation
import Observation
import OSLog
import Core
import Algorithms

/// OBS-01: continuously consumes ScanCoordinator + HealthProbe state, runs the DecisionEngine,
/// and emits Decisions to OSLog and an in-memory ring buffer. In `.observe` mode (the default)
/// no switching code is ever invoked — the loop just observes and logs.
///
/// OBS-03: the state machine state (steady / degraded / switching / cooldown) is exposed
/// via `state.fsm` so the menubar (Phase 6) and InspectorView can show it.
///
/// Phase 5 will inject a closure that the loop calls when a `.switchTo` decision arrives
/// and the mode is `.on` — for now the loop only emits; it does not execute.
@MainActor
@Observable
public final class DecisionLoop {
    public private(set) var mode: AutoSwitchMode = .observe
    public private(set) var engineState = DecisionState(fsm: .steady)
    public private(set) var lastDecision: Decision?
    public private(set) var log: [Decision] = []
    public var config: AlgorithmConfig = .default

    public var onSwitchRequested: ((CandidateKey) -> Void)?

    private static let maxInMemoryLog = 500
    private let osLog = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "DecisionLoop")
    private let engine: DecisionEngine

    private weak var scan: ScanCoordinator?
    private weak var health: HealthProbe?
    private weak var captive: CaptiveProbe?

    private var loopTask: Task<Void, Never>?

    public init(config: AlgorithmConfig = .default) {
        self.config = config
        self.engine = DecisionEngine(config: config)
    }

    public func attach(scan: ScanCoordinator, health: HealthProbe, captive: CaptiveProbe) {
        self.scan = scan
        self.health = health
        self.captive = captive
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
    }

    /// One evaluation cycle: gather state, run the engine, fold the decision into the log,
    /// and update FSM bookkeeping. Exposed for tests and for the manual "Refresh" button.
    public func tickOnce() async {
        guard mode != .off else { return }
        guard let scan, let health, let captive else { return }

        let snap = scan.snapshot
        // The DecisionEngine ignores `health` for non-current candidates, so we only need
        // the latest sample (it lives in @Observable storage; HealthProbe writes it
        // periodically).
        let healthSample = health.lastSample
        let captiveFlags = await capturedCaptiveFlags(captive: captive, snapshot: snap)
        let currentKey: CandidateKey? = {
            guard let ssid = snap.currentSSID, let band = snap.currentBand else { return nil }
            return CandidateKey(ssid: ssid, bssid: snap.currentBSSID, band: band, channel: snap.currentChannel ?? 0)
        }()

        let inputs = DecisionInputs(
            candidates: snap.allInRange,
            currentKey: currentKey,
            currentRSSI: snap.currentRSSI,
            health: healthSample,
            preferences: [:],  // Phase 7 (BG-04) will surface the persisted prefs here.
            captiveFlags: captiveFlags,
            now: Date()
        )

        let (newState, decision) = engine.evaluate(state: engineState, inputs: inputs)
        engineState = newState
        lastDecision = decision
        appendLog(decision)

        // Drive the scan cadence from the FSM state — SCAN-01 in service of the state
        // machine. In observe mode we still adapt cadence (cheap and harmless).
        scan.setCadence(scanCadence(for: newState.fsm))

        switch decision.action {
        case .switchTo(let target):
            osLog.info("decision: switchTo \(target.ssid, privacy: .public) (mode=\(self.mode.rawValue, privacy: .public))")
            if mode == .on {
                onSwitchRequested?(target)
                engine.markSwitchAttempted(state: &engineState, at: Date())
            }
        case .stay, .stayCurrentGoodEnough, .rejectedSwitch, .rejectedSwitchCooldown, .noCurrentConnection:
            osLog.debug("decision: \(self.actionLabel(decision.action), privacy: .public) — \(decision.reason, privacy: .public)")
        }
    }

    /// Filter the log for the decision-log view (UI-04).
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
        case .errors:
            // "Errors" is reserved for switch-execution failures (Phase 5 will populate).
            return []
        }
    }

    public func clearLog() {
        log.removeAll()
        lastDecision = nil
    }

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

    private func capturedCaptiveFlags(captive: CaptiveProbe, snapshot: WiFiSnapshot) async -> [CandidateKey: Bool] {
        // Captive verdicts are stored per (SSID, BSSID) in the actor — pull what we have
        // for the visible candidates.
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
