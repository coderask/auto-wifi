import Foundation
import Algorithms
import Core

// CLT doesn't ship XCTest or swift-testing, so this is a poor-man's test runner. Each
// `test()` call runs a scenario, asserts expected behavior, prints PASS/FAIL, and counts
// failures for a non-zero exit code on any failure. `swift run AlgorithmsRunner` runs it;
// `make test` chains it.

struct AssertionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class Runner {
    var passed = 0
    var failed = 0
    var failures: [String] = []

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failed += 1
            failures.append("\(name): \(error)")
            print("  ✗ \(name): \(error)")
        }
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "") throws {
    if actual != expected {
        throw AssertionError("\(label) expected \(expected), got \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ label: String) throws {
    if !condition { throw AssertionError(label) }
}

func assertCase(_ decision: Decision, isStay: Bool = false, isRejected: Bool = false, isSwitch: Bool = false, _ label: String = "") throws {
    switch decision.action {
    case .stay, .stayCurrentGoodEnough, .noCurrentConnection:
        if !isStay { throw AssertionError("\(label) expected non-stay action, got \(decision.action) — \(decision.reason)") }
    case .rejectedSwitch, .rejectedSwitchCooldown:
        if !isRejected { throw AssertionError("\(label) expected non-rejected, got \(decision.action) — \(decision.reason)") }
    case .switchTo:
        if !isSwitch { throw AssertionError("\(label) expected non-switch, got \(decision.action) — \(decision.reason)") }
    }
}

// MARK: - Fixtures

let homeKey = CandidateKey(ssid: "Home", bssid: "aa:bb:cc:dd:ee:01", band: .band5GHz, channel: 36)
let cafeKey = CandidateKey(ssid: "Cafe", bssid: "11:22:33:44:55:66", band: .band5GHz, channel: 44)
let captiveKey = CandidateKey(ssid: "Airport-Free", bssid: "ff:ff:ff:11:22:33", band: .band2_4GHz, channel: 1)

func scan(_ key: CandidateKey, rssi: Int, known: Bool = true) -> Candidate {
    Candidate(
        scan: ScanResult(
            ssid: key.ssid,
            bssid: key.bssid,
            rssi: rssi,
            channel: key.channel,
            band: key.band,
            observedAt: Date()
        ),
        isKnown: known
    )
}

let healthyNow = HealthSample(
    latencyMillis: 20,
    dnsSuccess: true,
    captiveDetected: false,
    isExpensive: false,
    isConstrained: false,
    isConnected: true,
    measuredAt: Date()
)

/// Realistic health for a connection on weak RSSI — high latency, DNS failing.
let degradedNow = HealthSample(
    latencyMillis: 800,
    dnsSuccess: false,
    captiveDetected: false,
    isExpensive: false,
    isConstrained: false,
    isConnected: true,
    measuredAt: Date()
)

@main
@MainActor
struct Main {
    static func main() {
        let r = Runner()

        // MARK: - EMA tests

        print("EMA")
        r.test("first sample initializes value") {
            var ema = EMA(alpha: 0.3)
            ema.update(-65)
            try assertEqual(ema.value, -65)
        }
        r.test("subsequent samples are blended") {
            var ema = EMA(alpha: 0.3)
            ema.update(-65)
            ema.update(-75)
            let expected = 0.3 * -75 + 0.7 * -65
            try assertTrue(abs((ema.value ?? 0) - expected) < 1e-6, "expected \(expected), got \(ema.value ?? 0)")
        }
        r.test("reset clears value") {
            var ema = EMA(alpha: 0.3, initial: -60)
            ema.reset()
            try assertEqual(ema.value, nil)
        }

        // MARK: - Scoring tests

        print("\nScoring")
        r.test("RSSI score: -30 → 100") {
            let s = ScoringEngine(config: .default)
            let breakdown = s.score(CandidateInputs(key: homeKey, smoothedRSSI: -30, isCurrent: false, isCaptive: false, userPref: .neutral))
            try assertTrue(abs(breakdown.rssiComponent - 100) < 1e-6, "rssiComponent for -30 dBm should be 100, got \(breakdown.rssiComponent)")
        }
        r.test("RSSI score: -100 → 0") {
            let s = ScoringEngine(config: .default)
            let breakdown = s.score(CandidateInputs(key: homeKey, smoothedRSSI: -100, isCurrent: false, isCaptive: false, userPref: .neutral))
            try assertTrue(abs(breakdown.rssiComponent) < 1e-6, "rssiComponent for -100 dBm should be 0, got \(breakdown.rssiComponent)")
        }
        r.test("captive penalty dominates") {
            let s = ScoringEngine(config: .default)
            let breakdown = s.score(CandidateInputs(key: captiveKey, smoothedRSSI: -40, isCurrent: false, isCaptive: true, userPref: .neutral))
            try assertTrue(breakdown.total < -100, "captive should produce total < -100, got \(breakdown.total)")
        }
        r.test("preferred network gets boost") {
            let s = ScoringEngine(config: .default)
            let plain = s.score(CandidateInputs(key: homeKey, smoothedRSSI: -60, isCurrent: false, isCaptive: false, userPref: .neutral))
            let pref = s.score(CandidateInputs(key: homeKey, smoothedRSSI: -60, isCurrent: false, isCaptive: false, userPref: .prefer))
            try assertTrue(pref.total > plain.total + 19, "preferred should be ~20 higher")
        }
        r.test("neverAutoJoin is disqualifying") {
            // neverAutoJoin penalty is -1000; even at perfect RSSI (~100) + 5GHz boost (~5),
            // total is around -895 — well below any plausible competitor's score.
            let s = ScoringEngine(config: .default)
            let breakdown = s.score(CandidateInputs(key: homeKey, smoothedRSSI: -30, isCurrent: false, isCaptive: false, userPref: .neverAutoJoin))
            try assertTrue(breakdown.total < -800, "neverAutoJoin should produce total < -800, got \(breakdown.total)")
        }

        // MARK: - Hysteresis tests — the heart of the matter

        print("\nHysteresis — flapping prevention")

        r.test("steady state when current is above good-enough") {
            let engine = DecisionEngine()
            let state = DecisionState(currentKey: homeKey)
            let now = Date(timeIntervalSinceReferenceDate: 0)
            let inputs = DecisionInputs(
                candidates: [scan(homeKey, rssi: -55), scan(cafeKey, rssi: -50)],
                currentKey: homeKey,
                currentRSSI: -55,
                health: healthyNow,
                now: now
            )
            let (newState, decision) = engine.evaluate(state: state, inputs: inputs)
            try assertCase(decision, isStay: true, "current is healthy, should not even consider switching")
            try assertEqual(newState.fsm, .steady)
        }

        r.test("does not switch on a single weak sample") {
            let engine = DecisionEngine()
            let state = DecisionState(currentKey: homeKey)
            let now = Date(timeIntervalSinceReferenceDate: 0)
            let inputs = DecisionInputs(
                candidates: [scan(homeKey, rssi: -80), scan(cafeKey, rssi: -50)],
                currentKey: homeKey,
                currentRSSI: -80,
                health: healthyNow,
                now: now
            )
            let (_, decision) = engine.evaluate(state: state, inputs: inputs)
            try assertCase(decision, isStay: true, "must not switch on first weak sample; degrade dwell hasn't elapsed")
        }

        r.test("switches only after sustained degradation + candidate dwell") {
            let engine = DecisionEngine(config: .default)
            var state = DecisionState(currentKey: homeKey)
            var now = Date(timeIntervalSinceReferenceDate: 0)
            // Realistic scenario: current at -85 dBm has predictably bad health (high latency,
            // DNS failing). The health-aware scoring is essential here — perfect health on a
            // weak network can mathematically beat a fresh candidate's RSSI alone, which is
            // exactly the point of compound scoring.
            let weakInputs: (Date) -> DecisionInputs = { t in
                DecisionInputs(
                    candidates: [scan(homeKey, rssi: -85), scan(cafeKey, rssi: -40)],
                    currentKey: homeKey,
                    currentRSSI: -85,
                    health: degradedNow,
                    now: t
                )
            }
            var (newState, d1) = engine.evaluate(state: state, inputs: weakInputs(now))
            state = newState
            try assertCase(d1, isStay: true, "first weak sample: still in dwell")

            now = now.addingTimeInterval(5)
            (newState, d1) = engine.evaluate(state: state, inputs: weakInputs(now))
            state = newState
            try assertCase(d1, isStay: true, "5s in: still need 5s more dwell")

            now = now.addingTimeInterval(7)
            (newState, d1) = engine.evaluate(state: state, inputs: weakInputs(now))
            state = newState
            try assertCase(d1, isRejected: true, "12s in: degrade dwell done, but candidate dwell starts now")

            now = now.addingTimeInterval(9)
            (newState, d1) = engine.evaluate(state: state, inputs: weakInputs(now))
            state = newState
            try assertCase(d1, isSwitch: true, "21s in: both dwells elapsed, should switch")
            try assertEqual(state.fsm, .switching)
        }

        r.test("rejects switch when margin too small") {
            let engine = DecisionEngine(config: .default)
            var state = DecisionState(currentKey: homeKey)
            var now = Date(timeIntervalSinceReferenceDate: 0)
            let inputs: (Date) -> DecisionInputs = { t in
                DecisionInputs(
                    candidates: [scan(homeKey, rssi: -80), scan(cafeKey, rssi: -78)],
                    currentKey: homeKey,
                    currentRSSI: -80,
                    health: healthyNow,
                    now: t
                )
            }
            for _ in 0..<3 {
                let (s, _) = engine.evaluate(state: state, inputs: inputs(now))
                state = s
                now = now.addingTimeInterval(5)
            }
            let (_, decision) = engine.evaluate(state: state, inputs: inputs(now))
            try assertCase(decision, isRejected: true, "2 dBm advantage should not pass 15-point switch margin")
        }

        r.test("cooldown blocks further switches after recent switch") {
            let engine = DecisionEngine(config: .default)
            let state = DecisionState(currentKey: homeKey, lastSwitchAt: Date(timeIntervalSinceReferenceDate: 0))
            let now = Date(timeIntervalSinceReferenceDate: 5)
            let inputs = DecisionInputs(
                candidates: [scan(homeKey, rssi: -90), scan(cafeKey, rssi: -40)],
                currentKey: homeKey,
                currentRSSI: -90,
                health: healthyNow,
                now: now
            )
            let (newState, decision) = engine.evaluate(state: state, inputs: inputs)
            if case .rejectedSwitchCooldown(let remaining) = decision.action {
                try assertTrue(remaining > 20 && remaining < 30, "cooldown remaining should be ~25s, got \(remaining)")
            } else {
                throw AssertionError("expected rejectedSwitchCooldown, got \(decision.action)")
            }
            try assertEqual(newState.fsm, .cooldown)
        }

        r.test("captive network is never recommended") {
            let engine = DecisionEngine(config: .default)
            var state = DecisionState(currentKey: homeKey)
            var now = Date(timeIntervalSinceReferenceDate: 0)
            let captiveFlags: [CandidateKey: Bool] = [captiveKey: true]
            let inputs: (Date) -> DecisionInputs = { t in
                DecisionInputs(
                    candidates: [scan(homeKey, rssi: -85), scan(captiveKey, rssi: -35)],
                    currentKey: homeKey,
                    currentRSSI: -85,
                    health: healthyNow,
                    captiveFlags: captiveFlags,
                    now: t
                )
            }
            for _ in 0..<6 {
                let (next, decision) = engine.evaluate(state: state, inputs: inputs(now))
                state = next
                if case .switchTo(let target) = decision.action {
                    if target == captiveKey {
                        throw AssertionError("engine recommended switching to captive network")
                    }
                }
                now = now.addingTimeInterval(5)
            }
        }

        r.test("noisy RSSI does not cause flapping (EMA smoothing)") {
            let engine = DecisionEngine(config: .default)
            var state = DecisionState(currentKey: homeKey)
            var now = Date(timeIntervalSinceReferenceDate: 0)
            var rssiPattern: [Int] = []
            for _ in 0..<20 { rssiPattern += [-60, -78] }
            var switches = 0
            for rssi in rssiPattern {
                let inputs = DecisionInputs(
                    candidates: [scan(homeKey, rssi: rssi), scan(cafeKey, rssi: -55)],
                    currentKey: homeKey,
                    currentRSSI: rssi,
                    health: healthyNow,
                    now: now
                )
                let (next, decision) = engine.evaluate(state: state, inputs: inputs)
                state = next
                if case .switchTo = decision.action { switches += 1 }
                now = now.addingTimeInterval(2)
            }
            try assertEqual(switches, 0, "noisy RSSI averaging around -69 should not trigger any switches")
        }

        r.test("active-traffic raises margin") {
            let engine = DecisionEngine(config: .default)
            var state = DecisionState(currentKey: homeKey, activeTraffic: true)
            var now = Date(timeIntervalSinceReferenceDate: 0)
            let inputs: (Date) -> DecisionInputs = { t in
                DecisionInputs(
                    candidates: [scan(homeKey, rssi: -80), scan(cafeKey, rssi: -65)],
                    currentKey: homeKey,
                    currentRSSI: -80,
                    health: healthyNow,
                    now: t
                )
            }
            for _ in 0..<6 {
                let (s, _) = engine.evaluate(state: state, inputs: inputs(now))
                state = s
                now = now.addingTimeInterval(5)
            }
            let (_, decision) = engine.evaluate(state: state, inputs: inputs(now))
            try assertCase(decision, isRejected: true, "under active traffic, 15-point margin should NOT be enough")
        }

        // MARK: - Algorithms module sanity

        print("\nModule")
        r.test("version exposed") {
            try assertTrue(!Algorithms.version.isEmpty, "version string should be non-empty")
        }

        // MARK: - Summary

        print("\n———")
        print("\(r.passed) passed, \(r.failed) failed")
        if r.failed > 0 {
            print("\nFailures:")
            for f in r.failures { print("  • \(f)") }
            exit(1)
        }
        exit(0)
    }
}
