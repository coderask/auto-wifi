import Foundation
import Network
import Observation
import OSLog
import Core

/// HEAL-01 + HEAL-04: continuous health probing of the current network using the Network
/// framework — no third-party services. We measure two things on a rolling cadence:
///   1. TCP-connect latency to a public endpoint (apple.com:443) — proves DNS + routing +
///      handshake all work, and gives a real latency number in milliseconds.
///   2. Live `NWPath` flags from `NWPathMonitor` — `isExpensive` tells us when the user is
///      tethered to cellular, in which case we suppress probes (HEAL-04).
@MainActor
@Observable
public final class HealthProbe {
    public private(set) var lastSample: HealthSample = .pending

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "HealthProbe")
    private let pathMonitor = NWPathMonitor()
    private var pathState = PathState()
    private var probeTask: Task<Void, Never>?
    private var interval: Duration = .seconds(5)
    /// CaptiveProbe writes its latest result here so HealthSample can fold it in without
    /// every probe round having to make a captive request.
    private var lastCaptiveDetected = false

    public init() {}

    public func start(interval: Duration = .seconds(5)) {
        guard probeTask == nil else { return }
        self.interval = interval

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let snap = PathSnapshot(path: path)
            Task { @MainActor [weak self] in
                self?.pathState.apply(snap)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.aarnavkoushik.autowifi.path"))

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(for: self?.interval ?? .seconds(5))
            }
        }
    }

    public func stop() {
        probeTask?.cancel()
        probeTask = nil
        pathMonitor.cancel()
    }

    /// Called by CaptiveProbe whenever it has a new verdict for the currently-connected
    /// network. Folded into the next `HealthSample`.
    public func setCaptiveDetected(_ detected: Bool) {
        lastCaptiveDetected = detected
    }

    private func probeOnce() async {
        let snap = pathState.snapshot
        // HEAL-04: if the system reports we're on a metered link (cellular tether, etc.),
        // suppress active probing — the user is paying for those bytes.
        if snap.isExpensive {
            lastSample = HealthSample(
                latencyMillis: nil,
                dnsSuccess: false,
                captiveDetected: lastCaptiveDetected,
                isExpensive: true,
                isConstrained: snap.isConstrained,
                isConnected: snap.isConnected,
                measuredAt: Date()
            )
            return
        }
        // If we have no usable network at all, don't bother probing.
        if !snap.isConnected {
            lastSample = HealthSample(
                latencyMillis: nil,
                dnsSuccess: false,
                captiveDetected: lastCaptiveDetected,
                isExpensive: snap.isExpensive,
                isConstrained: snap.isConstrained,
                isConnected: false,
                measuredAt: Date()
            )
            return
        }
        let result = await TCPProbe.run(host: "apple.com", port: 443, timeout: .seconds(3))
        lastSample = HealthSample(
            latencyMillis: result.latencyMillis,
            dnsSuccess: result.success,
            captiveDetected: lastCaptiveDetected,
            isExpensive: snap.isExpensive,
            isConstrained: snap.isConstrained,
            isConnected: snap.isConnected,
            measuredAt: Date()
        )
        log.debug("health: latency=\(result.latencyMillis ?? -1, privacy: .public) ms dns=\(result.success, privacy: .public) captive=\(self.lastCaptiveDetected, privacy: .public) expensive=\(snap.isExpensive, privacy: .public)")
    }
}

/// Mutable, main-actor-isolated path state. Update from the NWPathMonitor handler.
@MainActor
private struct PathState {
    var snapshot: PathSnapshot = PathSnapshot(isConnected: false, isExpensive: false, isConstrained: false)

    mutating func apply(_ new: PathSnapshot) {
        snapshot = new
    }
}

private struct PathSnapshot: Sendable {
    let isConnected: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    init(isConnected: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(path: NWPath) {
        self.isConnected = path.status == .satisfied
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
    }
}

/// One-shot TCP probe via `NWConnection`. Times the round-trip from `start()` to `.ready`.
/// Returns success+latency or a failure with `latencyMillis == nil`.
enum TCPProbe {
    struct Result: Sendable {
        let success: Bool
        let latencyMillis: Double?
    }

    static func run(host: String, port: Int, timeout: Duration) async -> Result {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        let connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                await measure(connection: connection)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                connection.cancel()
                return Result(success: false, latencyMillis: nil)
            }
            let first = await group.next() ?? Result(success: false, latencyMillis: nil)
            group.cancelAll()
            connection.cancel()
            return first
        }
    }

    private static func measure(connection: NWConnection) async -> Result {
        let start = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let box = OnceBox<Result>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Date().timeIntervalSince(start) * 1000
                    box.resolve(Result(success: true, latencyMillis: elapsed)) { result in
                        continuation.resume(returning: result)
                    }
                case .failed, .cancelled:
                    box.resolve(Result(success: false, latencyMillis: nil)) { result in
                        continuation.resume(returning: result)
                    }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.aarnavkoushik.autowifi.tcpprobe"))
        }
    }
}

/// Lock-protected single-shot continuation resolver. Used because `NWConnection.stateUpdateHandler`
/// can fire `.ready` then `.cancelled` and we must call the continuation exactly once.
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(_ value: T, _ block: (T) -> Void) {
        lock.lock()
        let firstTime = !resolved
        resolved = true
        lock.unlock()
        if firstTime { block(value) }
    }
}
