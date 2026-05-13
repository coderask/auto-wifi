import Foundation
import Observation
import OSLog
import Core
import Algorithms

/// Top-level @Observable owned by the SwiftUI app. Owns every long-running component and
/// wires them together. Phase 5 adds GuardState + TrafficWatcher + SwitchActor (via the
/// DecisionLoop).
@MainActor
@Observable
public final class AppState {
    public let scan = ScanCoordinator()
    public let health = HealthProbe()
    public let captive = CaptiveProbe()
    public let traffic = TrafficWatcher()
    public let guards = GuardState()
    public let decisions = DecisionLoop()

    /// UI-05: per-network preference (prefer / avoid / never-auto-join). In-memory in Phase 6;
    /// SwiftData-backed in Phase 7. The DecisionLoop reads from this map every tick via the
    /// preferences-provider closure set in `attach()`.
    public var networkPreferences: [String: NetworkPreference] = [:]

    public private(set) var isRunning = false
    public private(set) var captiveVerdict: CaptiveProbe.Verdict?
    private var captiveTask: Task<Void, Never>?
    private var lastProbedBSSID: String?

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "AppState")

    public init() {
        decisions.attach(scan: scan, health: health, captive: captive, guards: guards, traffic: traffic)
        decisions.preferencesProvider = { [weak self] in self?.networkPreferences ?? [:] }
    }

    public func setPreference(_ pref: NetworkPreference, for ssid: String) {
        if pref == .neutral {
            networkPreferences.removeValue(forKey: ssid)
        } else {
            networkPreferences[ssid] = pref
        }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        log.info("AppState starting")
        await scan.start()
        health.start()
        traffic.start()
        decisions.start()
        captiveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maybeProbeCaptive()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func stop() {
        log.info("AppState stopping")
        isRunning = false
        scan.stop()
        health.stop()
        traffic.stop()
        decisions.stop()
        captiveTask?.cancel()
        captiveTask = nil
    }

    public func refreshNow() async {
        await scan.refreshNow()
        await maybeProbeCaptive(force: true)
        await decisions.tickOnce()
    }

    /// One-click "stop touching my Wi-Fi for N minutes" (SW-03). Phase 6's menubar surfaces
    /// this; for now the inspector wires a button.
    public func pauseAutoSwitch(for duration: TimeInterval) {
        guards.pause(for: duration)
    }

    public func clearAllHolds() {
        guards.clearManualHold()
        guards.clearPause()
    }

    private func maybeProbeCaptive(force: Bool = false) async {
        let currentSSID = scan.snapshot.currentSSID
        let currentBSSID = scan.snapshot.currentBSSID
        guard let currentSSID, !currentSSID.isEmpty else {
            health.setCaptiveDetected(false)
            captiveVerdict = nil
            return
        }
        if !force, currentBSSID == lastProbedBSSID, let cached = await captive.cachedVerdict(ssid: currentSSID, bssid: currentBSSID) {
            health.setCaptiveDetected(cached.captive)
            captiveVerdict = cached
            return
        }
        lastProbedBSSID = currentBSSID
        let detected = await captive.probeCurrent(ssid: currentSSID, bssid: currentBSSID)
        health.setCaptiveDetected(detected)
        captiveVerdict = await captive.cachedVerdict(ssid: currentSSID, bssid: currentBSSID)
    }
}
