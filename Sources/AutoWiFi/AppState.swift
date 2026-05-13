import Foundation
import Observation
import OSLog
import Core
import Algorithms

/// Top-level @Observable owned by the SwiftUI app. Phase 7 adds Persistence + LoginItemManager
/// and runs an hourly prune for the decision-log rollover (BG-05).
@MainActor
@Observable
public final class AppState {
    public let scan = ScanCoordinator()
    public let health = HealthProbe()
    public let captive = CaptiveProbe()
    public let traffic = TrafficWatcher()
    public let guards = GuardState()
    public let decisions = DecisionLoop()
    public let loginItem = LoginItemManager()

    /// In-memory mirror of persisted per-network preferences (BG-04). Mutations write
    /// through to PersistenceActor; reads happen here for sync access from DecisionLoop.
    public private(set) var networkPreferences: [String: NetworkPreference] = [:]

    public private(set) var isRunning = false
    public private(set) var captiveVerdict: CaptiveProbe.Verdict?
    private var captiveTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var lastProbedBSSID: String?

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "AppState")

    public init() {
        decisions.attach(scan: scan, health: health, captive: captive, guards: guards, traffic: traffic)
        decisions.preferencesProvider = { [weak self] in self?.networkPreferences ?? [:] }
        decisions.persistenceSink = { @Sendable decision in
            Task.detached { await PersistenceActor.shared.appendDecision(decision) }
        }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        log.info("AppState starting")

        // Load persisted state first so the engine sees yesterday's preferences and captive
        // flags immediately rather than after a 30s probe.
        let loadedPrefs = await PersistenceActor.shared.loadPreferences()
        networkPreferences = loadedPrefs
        let loadedFlags = await PersistenceActor.shared.loadCaptiveFlags()
        for f in loadedFlags {
            await captive.seedVerdict(ssid: f.ssid, bssid: f.bssid, captive: f.captive, observedAt: f.observedAt)
        }
        log.info("loaded \(loadedPrefs.count, privacy: .public) preferences + \(loadedFlags.count, privacy: .public) captive flags from disk")

        await scan.start()
        health.start()
        traffic.start()
        decisions.start()
        loginItem.refresh()

        captiveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maybeProbeCaptive()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // BG-05: prune decision log on launch and every hour.
        pruneTask = Task {
            await PersistenceActor.shared.pruneDecisions()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await PersistenceActor.shared.pruneDecisions()
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
        pruneTask?.cancel()
        pruneTask = nil
    }

    public func refreshNow() async {
        await scan.refreshNow()
        await maybeProbeCaptive(force: true)
        await decisions.tickOnce()
    }

    public func pauseAutoSwitch(for duration: TimeInterval) {
        guards.pause(for: duration)
    }

    public func clearAllHolds() {
        guards.clearManualHold()
        guards.clearPause()
    }

    public func setPreference(_ pref: NetworkPreference, for ssid: String) {
        if pref == .neutral {
            networkPreferences.removeValue(forKey: ssid)
        } else {
            networkPreferences[ssid] = pref
        }
        Task.detached {
            await PersistenceActor.shared.savePreference(ssid: ssid, preference: pref)
        }
    }

    public func clearAllPreferences() {
        let cleared = networkPreferences.keys
        networkPreferences.removeAll()
        Task.detached {
            for ssid in cleared {
                await PersistenceActor.shared.savePreference(ssid: ssid, preference: NetworkPreference.neutral)
            }
        }
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
        // BG-04: persist the captive verdict so we don't have to re-probe next launch.
        Task.detached {
            await PersistenceActor.shared.saveCaptiveFlag(ssid: currentSSID, bssid: currentBSSID, captive: detected)
        }
    }
}
