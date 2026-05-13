import Foundation
import Darwin
import Observation
import OSLog

/// SW-04: detect when the user is in the middle of a live call or large transfer so the
/// DecisionEngine can raise the switch margin (engineState.activeTraffic = true) and avoid
/// kicking the user off mid-Zoom.
///
/// We use `getifaddrs`'s `if_data` byte counters on the Wi-Fi interface — same data
/// Activity Monitor uses. Sampling every 2s with a 500 KB/s threshold catches calls (steady
/// bidirectional UDP) and large downloads/uploads without false-positive on idle traffic.
@MainActor
@Observable
public final class TrafficWatcher {
    public private(set) var rxBytesPerSec: Double = 0
    public private(set) var txBytesPerSec: Double = 0
    public private(set) var isActiveTraffic = false

    /// Bytes-per-second above which we consider the link "in use." 500 KB/s is conservative —
    /// a 1080p Zoom call sits around 1.5 Mbps (~190 KB/s) bidirectional, but the user is
    /// probably also downloading other things during it. Calibrated for the false-positive
    /// trade-off described in `research/PITFALLS.md`.
    public var activeThreshold: Double = 500_000

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "TrafficWatcher")
    private var lastSample: (rx: UInt64, tx: UInt64, at: Date)?
    private var task: Task<Void, Never>?

    public init() {}

    public func start(interval: Duration = .seconds(2)) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lastSample = nil
        rxBytesPerSec = 0
        txBytesPerSec = 0
        isActiveTraffic = false
    }

    private func tick() async {
        guard let counters = readWiFiCounters() else { return }
        let now = Date()
        defer { lastSample = (counters.rx, counters.tx, now) }
        guard let prev = lastSample else { return }
        let elapsed = now.timeIntervalSince(prev.at)
        guard elapsed > 0 else { return }
        let rxRate = Double(counters.rx &- prev.rx) / elapsed
        let txRate = Double(counters.tx &- prev.tx) / elapsed
        rxBytesPerSec = max(0, rxRate)
        txBytesPerSec = max(0, txRate)
        let newActive = rxRate > activeThreshold || txRate > activeThreshold
        if newActive != isActiveTraffic {
            log.info("active traffic \(self.isActiveTraffic, privacy: .public) → \(newActive, privacy: .public) (rx=\(rxRate, privacy: .public) tx=\(txRate, privacy: .public))")
        }
        isActiveTraffic = newActive
    }

    /// Walk `getifaddrs` and sum byte counters from any AF_LINK entry whose interface name
    /// starts with `en` (matches `en0`, `en1`, …). On most Macs `en0` is the Wi-Fi adapter,
    /// but on Mac Pros and some Mac Studios it can be `en1` — summing handles both cases
    /// without hardcoding.
    private func readWiFiCounters() -> (rx: UInt64, tx: UInt64)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var found = false
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let p = current {
            let addr = p.pointee
            if let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: addr.ifa_name)
                if name.hasPrefix("en"), let dataPtr = addr.ifa_data {
                    let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    totalRx &+= UInt64(data.ifi_ibytes)
                    totalTx &+= UInt64(data.ifi_obytes)
                    found = true
                }
            }
            current = addr.ifa_next
        }
        return found ? (totalRx, totalTx) : nil
    }
}
