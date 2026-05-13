import Foundation
import Observation
import OSLog

/// SW-02 + SW-03: two reasons the engine should not execute switches even when it has
/// decided one is justified — the user manually joined a different network (manual hold)
/// or the user explicitly asked us to chill out (pause).
///
/// Both gates work by setting an "expiry" timestamp. While the timestamp is in the future,
/// `isHeld` is true and DecisionLoop treats the effective mode as `.observe` regardless of
/// the user's chosen mode. The countdown is visible to the UI (menubar tooltip in Phase 6).
@MainActor
@Observable
public final class GuardState {
    public private(set) var manualHoldUntil: Date?
    public private(set) var pauseUntil: Date?

    public static let defaultManualHoldDuration: TimeInterval = 10 * 60   // 10 minutes (SW-02)

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "GuardState")

    public init() {}

    public var manualHoldRemaining: TimeInterval? {
        guard let until = manualHoldUntil else { return nil }
        let r = until.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    public var pauseRemaining: TimeInterval? {
        guard let until = pauseUntil else { return nil }
        let r = until.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    public var isHeld: Bool {
        (manualHoldRemaining ?? 0) > 0 || (pauseRemaining ?? 0) > 0
    }

    public var holdReason: String? {
        if let r = manualHoldRemaining { return "manual hold (\(formatRemaining(r)))" }
        if let r = pauseRemaining { return "paused (\(formatRemaining(r)))" }
        return nil
    }

    public func enterManualHold(duration: TimeInterval = defaultManualHoldDuration) {
        log.info("entering manual hold for \(duration)s")
        manualHoldUntil = Date().addingTimeInterval(duration)
    }

    public func clearManualHold() {
        log.info("manual hold cleared")
        manualHoldUntil = nil
    }

    public func pause(for duration: TimeInterval) {
        log.info("pausing for \(duration)s")
        pauseUntil = Date().addingTimeInterval(duration)
    }

    public func clearPause() {
        log.info("pause cleared")
        pauseUntil = nil
    }

    private func formatRemaining(_ s: TimeInterval) -> String {
        if s < 60 { return String(format: "%.0fs left", s) }
        return String(format: "%.1fm left", s / 60)
    }
}
