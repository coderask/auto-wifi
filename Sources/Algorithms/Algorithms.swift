/// `Algorithms` — the pure-logic core of auto-wifi.
///
/// Per `ARCHITECTURE.md` "Pattern 5: pure-logic core, side-effecting shell":
///   - This module declares **zero** system framework imports — no CoreWLAN, no Network,
///     no AppKit, no SwiftUI. Foundation (for `Date`, `UUID`) is the only system import.
///   - All entry points are pure functions or value-typed engines. State (`DecisionState`)
///     is held by the caller and passed in; the engine returns the next state alongside
///     the decision.
///   - Tests run with fully synthetic inputs — no radio, no network, no clock.
///
/// The public entry point is `DecisionEngine.evaluate(state:inputs:)`.

public enum Algorithms {
    public static let version = "0.1.0-phase-3"
}
