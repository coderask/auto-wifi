import Foundation
import Observation
import OSLog
import Core

/// Top-level @Observable owned by the SwiftUI app. Phases 2+ will inject a real engine here;
/// for Phase 1 it just owns the last snapshot, the last error, and a "refresh" trigger.
@MainActor
@Observable
public final class AppState {
    public private(set) var snapshot: WiFiSnapshot = .empty
    public private(set) var lastError: String?
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshedAt: Date?

    private let inspector = WiFiInspector()
    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "AppState")
    private var pollingTask: Task<Void, Never>?

    public init() {}

    /// Begin a slow background refresh loop so the UI stays warm. Phase 1 uses a naive
    /// fixed interval — Phase 2 introduces the adaptive scan cadence (per SCAN-01).
    public func startPolling(every interval: Duration = .seconds(15)) {
        guard pollingTask == nil else { return }
        log.info("polling started")
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// One-shot refresh. Safe to call from the UI on a button tap.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snap = try await inspector.snapshot()
            snapshot = snap
            lastError = nil
            lastRefreshedAt = Date()
            log.debug("snapshot: current=\(snap.currentSSID ?? "nil", privacy: .public) known-in-range=\(snap.knownInRange.count, privacy: .public) total=\(snap.allInRange.count, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
