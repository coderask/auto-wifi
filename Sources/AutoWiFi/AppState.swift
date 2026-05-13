import Foundation
import Observation
import OSLog
import Core

/// Top-level @Observable owned by the SwiftUI app. Aggregates the long-running components
/// (scanning, health probing, captive detection) and exposes their state to the views.
/// Phase 4 will replace the direct composition with a `DecisionLoop` that orchestrates them
/// through a state machine; for Phase 2 the loop is naïve "do all three on similar cadence."
@MainActor
@Observable
public final class AppState {
    public let scan = ScanCoordinator()
    public let health = HealthProbe()
    public let captive = CaptiveProbe()

    public private(set) var isRunning = false
    public private(set) var captiveVerdict: CaptiveProbe.Verdict?
    private var captiveTask: Task<Void, Never>?
    private var lastProbedBSSID: String?

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "AppState")

    public init() {}

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        log.info("AppState starting")
        await scan.start()
        health.start()
        captiveTask = Task { [weak self] in
            // The captive probe is cheap-ish but not free — only run when the BSSID changes
            // (i.e., we joined a new AP). Cached per-(SSID,BSSID) verdict avoids re-probing.
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
        captiveTask?.cancel()
        captiveTask = nil
    }

    public func refreshNow() async {
        await scan.refreshNow()
        await maybeProbeCaptive(force: true)
    }

    private func maybeProbeCaptive(force: Bool = false) async {
        let currentSSID = scan.snapshot.currentSSID
        let currentBSSID = scan.snapshot.currentBSSID
        guard let currentSSID, !currentSSID.isEmpty else {
            health.setCaptiveDetected(false)
            captiveVerdict = nil
            return
        }
        // Skip re-probing the same AP unless forced — captive status doesn't flip without a
        // re-association.
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
