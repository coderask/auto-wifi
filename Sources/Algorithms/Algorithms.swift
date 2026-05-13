// Placeholder for the pure-logic scoring + hysteresis library.
//
// Per ARCHITECTURE.md "Pattern 5: Pure-logic core, side-effecting shell" and SUMMARY.md
// "Phase 3: Pure Scoring + Hysteresis Engine," this module MUST NOT import any system
// framework. It will be exercised entirely with synthetic inputs in `swift test`.
//
// Phase 3 populates this with: EMA smoothing, threshold bands, dwell timers, compound
// scoring, post-switch cooldown — all callable as `(scan, health, prefs, prior) -> Decision`.

public enum Algorithms {
    /// Library version surfaced for the diagnostic "About" panel.
    public static let version = "0.0.0-placeholder"
}
