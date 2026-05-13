import Foundation
import Observation
import OSLog
import Core
import Algorithms

/// Top-level @Observable owned by the SwiftUI app. Aggregates the long-running components
/// (scanning, health probing, captive detection, decision loop) and exposes their state to
/// the views. Phase 5 layers SwitchActor on top via DecisionLoop.onSwitchRequested.
@MainActor
@Observable
public final class AppState {
    public let scan = ScanCoordinator()
    public let health = HealthProbe()
    public let captive = CaptiveProbe()
    public let decisions = DecisionLoop()

    public private(set) var isRunning = false
    public private(set) var captiveVerdict: CaptiveProbe.Verdict?
    private var captiveTask: Task<Void, Never>?
    private var lastProbedBSSID: String?

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "AppState")

    public init() {
        decisions.attach(scan: scan, health: health, captive: captive)
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        log.info("AppState starting")
        await scan.start()
        health.start()
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
        decisions.stop()
        captiveTask?.cancel()
        captiveTask = nil
    }

    public func refreshNow() async {
        await scan.refreshNow()
        await maybeProbeCaptive(force: true)
        await decisions.tickOnce()
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
