import Foundation

/// OBS-02: the three-way toggle that controls whether the engine ever acts. Defaults to
/// `.observe` on first launch so the user can validate the algorithm against ground truth
/// before letting it touch the radio.
public enum AutoSwitchMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case off
    case observe
    case on

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .observe: "Observe"
        case .on: "On"
        }
    }

    public var description: String {
        switch self {
        case .off: "Engine paused. No scoring, no decisions."
        case .observe: "Engine runs and logs decisions, but never switches networks."
        case .on: "Engine switches to better known networks when hysteresis gates pass."
        }
    }
}
