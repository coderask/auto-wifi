import Foundation
import CoreWLAN
import Observation
import OSLog
import Core

/// Continuous, event-driven WiFi scanning.
///
/// SCAN-01 (adaptive cadence): callers tell us the current "tempo" — `.steady` for the long
/// 60s interval used when the connection is healthy, `.degraded` for the fast 10s interval
/// used when health probes signal trouble, `.cooldown` to pause for 30s after a switch.
/// Phase 4 owns the policy; this class just executes it.
///
/// SCAN-02 (event-driven): we subscribe to `scanCacheUpdated` via `CWEventDelegate` so when
/// the system already has fresh data (someone else triggered a scan, the radio woke up, etc.)
/// we refresh immediately without forcing another active scan.
///
/// SCAN-04 (caching): the last snapshot is held in `@Observable` storage; UI reads are
/// instantaneous and never block on the radio.
@MainActor
@Observable
public final class ScanCoordinator {
    public enum Cadence: Sendable, Equatable {
        case steady
        case degraded
        case cooldown

        public var interval: Duration {
            switch self {
            case .steady: .seconds(60)
            case .degraded: .seconds(10)
            case .cooldown: .seconds(30)
            }
        }
    }

    public private(set) var snapshot: WiFiSnapshot = .empty
    public private(set) var lastError: String?
    public private(set) var lastScannedAt: Date?
    public private(set) var cadence: Cadence = .steady

    private let inspector = WiFiInspector()
    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "ScanCoordinator")
    private var pollingTask: Task<Void, Never>?
    private var eventBridge: WiFiEventBridge?
    private var eventConsumer: Task<Void, Never>?

    public init() {}

    public func start() async {
        guard pollingTask == nil else { return }
        log.info("ScanCoordinator starting (cadence=\(self.cadence.label, privacy: .public))")
        await refreshNow()
        installEventBridge()
        startPolling()
    }

    public func stop() {
        log.info("ScanCoordinator stopping")
        pollingTask?.cancel()
        pollingTask = nil
        eventConsumer?.cancel()
        eventConsumer = nil
        eventBridge?.detach()
        eventBridge = nil
    }

    public func setCadence(_ new: Cadence) {
        guard new != cadence else { return }
        log.info("cadence \(self.cadence.label, privacy: .public) → \(new.label, privacy: .public)")
        cadence = new
        pollingTask?.cancel()
        startPolling()
    }

    public func refreshNow() async {
        do {
            let snap = try await inspector.snapshot()
            snapshot = snap
            lastScannedAt = Date()
            lastError = nil
            log.debug("scan: current=\(snap.currentSSID ?? "nil", privacy: .public) known-in-range=\(snap.knownInRange.count, privacy: .public) total=\(snap.allInRange.count, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startPolling() {
        let interval = cadence.interval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshNow()
            }
        }
    }

    private func installEventBridge() {
        let (stream, continuation) = AsyncStream<WiFiEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let bridge = WiFiEventBridge(continuation: continuation)
        bridge.attach()
        eventBridge = bridge

        eventConsumer = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleEvent(event)
                }
            }
        }
    }

    private func handleEvent(_ event: WiFiEvent) async {
        log.debug("event: \(event.label, privacy: .public)")
        // For any meaningful event, refresh the snapshot. `scanCacheUpdated` is the cheap
        // case — we read the cached results without an active scan.
        switch event {
        case .scanCacheUpdated, .linkChanged, .bssidChanged, .ssidChanged, .linkQualityChanged:
            await refreshNow()
        }
    }
}

extension ScanCoordinator.Cadence {
    var label: String {
        switch self {
        case .steady: "steady"
        case .degraded: "degraded"
        case .cooldown: "cooldown"
        }
    }
}

// MARK: - CoreWLAN event bridge

enum WiFiEvent: Sendable {
    case scanCacheUpdated
    case linkChanged
    case bssidChanged
    case ssidChanged
    case linkQualityChanged

    var label: String {
        switch self {
        case .scanCacheUpdated: "scanCacheUpdated"
        case .linkChanged: "linkChanged"
        case .bssidChanged: "bssidChanged"
        case .ssidChanged: "ssidChanged"
        case .linkQualityChanged: "linkQualityChanged"
        }
    }
}

/// Adapter from `CWEventDelegate` (called by CoreWLAN on a private queue) onto an
/// `AsyncStream<WiFiEvent>`. Yielding into a continuation is safe across threads — the
/// `@unchecked Sendable` is correct because we only ever read `continuation` (immutable
/// after init) and continuations are themselves thread-safe.
final class WiFiEventBridge: NSObject, CWEventDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<WiFiEvent>.Continuation
    private let client = CWWiFiClient.shared()

    init(continuation: AsyncStream<WiFiEvent>.Continuation) {
        self.continuation = continuation
    }

    func attach() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .scanCacheUpdated)
        try? client.startMonitoringEvent(with: .linkDidChange)
        try? client.startMonitoringEvent(with: .bssidDidChange)
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkQualityDidChange)
    }

    func detach() {
        try? client.stopMonitoringAllEvents()
        if client.delegate === self {
            client.delegate = nil
        }
        continuation.finish()
    }

    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        continuation.yield(.scanCacheUpdated)
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        continuation.yield(.linkChanged)
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        continuation.yield(.bssidChanged)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        continuation.yield(.ssidChanged)
    }

    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        continuation.yield(.linkQualityChanged)
    }
}
