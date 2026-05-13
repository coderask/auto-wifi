# Project Research Summary

**Project:** auto-wifi
**Domain:** Native macOS GUI utility — intelligent WiFi auto-switching with signal + throughput scoring, hysteresis, and a transparent decision log
**Researched:** 2026-05-12
**Confidence:** HIGH overall (one MEDIUM area — exact CoreWLAN scan rate-limits on macOS 14.4+ are undocumented and need empirical validation in Phase 1)

## Executive Summary

`auto-wifi` is a near-greenfield product category on macOS: every passive WiFi analyzer (NetSpot, WiFi Explorer, iStumbler) and every menubar signal widget (WiFi Signal, Wifiry) leaves the "actually switch to the better network" column empty, and Apple's own `joinMode=Strongest` is single-axis, opaque, and reportedly weakened in recent macOS versions. The thinness of this competitive space means the project's portfolio value is concentrated in three things experts agree must exist: (1) cross-SSID auto-switching with multi-layer hysteresis (EWMA smoothing + threshold bands + dwell timers + post-switch cooldown), (2) a compound score combining RSSI with measured health (ping/DNS/path) rather than RSSI alone, and (3) a first-class structured decision log explaining *why* every switch happened — including switches considered and rejected. All four researchers converged independently on these three pillars; that level of agreement is high-signal and should be treated as load-bearing.

The recommended technical approach is opinionated and modern: **Swift 6.2 + SwiftUI in an Xcode 26 project** targeting macOS 14+, using **CoreWLAN** for scanning/association, **CoreLocation** to unlock SSID/BSSID visibility (mandatory and the single biggest UX gotcha), **Network framework** for cheap health probes, **`SMAppService.agent(plistName:)`** for the background helper, and **SwiftData** for the decision log. Distribute as a **signed + notarized `.app`** (Developer ID + hardened runtime + `xcrun notarytool` — `altool` is decommissioned) with an optional **Homebrew Cask**. Internal modularization via **local SwiftPM packages** (a pure `Algorithms` library is the testable core). The structural decision that pays for itself: keep the scoring + hysteresis engine as a pure, framework-free Swift module with `(scan, health, prefs, prior) -> Decision` signatures so it can be fully unit-tested with synthetic inputs before any radio I/O exists.

The key risks are all front-loaded and well-characterized. **Location Services authorization** is the single biggest gotcha — without it every SSID/BSSID returns `nil` and the app silently fails (gates everything else; must be Phase 1, not polish). **Distribute as a real `.app` bundle from day one** — a bare CLI binary cannot get Location auth at all. **Adopt `SMAppService` (macOS 13+), not legacy LaunchAgent plists** — both stack and architecture agree the legacy path is deprecated and triggers "Background item added" surprises. **Set up the notarization pipeline in Phase 1-2, not at ship time** — discovering signing failures late is panic-inducing. **Hysteresis is the product**: a naive max-RSSI selector would *be* the bug this app is meant to fix, so the multi-layer hysteresis logic must exist before any switching code is wired in. **Captive portals cannot be pre-detected via any native API**, so the app must probe `captive.apple.com` after association and learn a per-SSID flag — and never auto-switch to flagged-captive networks.

## Key Findings

### Recommended Stack

Native Swift 6.2 + SwiftUI is the only sensible choice — Electron/Tauri are non-starters because they would foreclose CoreWLAN access, and the portfolio framing depends on shipping native. Xcode project (not pure SwiftPM) because entitlements, Info.plist UI, asset catalogs, and the archive→notarize flow all require it; internal pure-logic modules live in local SwiftPM packages within the workspace.

**Core technologies:**
- **Swift 6.2 / SwiftUI** (Xcode 26+, macOS 14+ deployment target): strict-concurrency safety for the continuously-running background loop
- **CoreWLAN** (`CWWiFiClient` + `CWInterface` + `CWEventDelegate`): the only sanctioned API for live scan results, RSSI, and `associate(...)`. Not thread-safe → must be serialized through a single actor
- **CoreLocation**: mandatory gate for SSID/BSSID visibility since macOS 11; strictly enforced from 14.4+. `requestAlwaysAuthorization()` for background scanning
- **Network framework** (`NWPathMonitor`, `NWConnection`): cheap UDP/TCP probes for latency and reachability
- **`SMAppService.agent(plistName:)`** (macOS 13+): modern, supported background-agent path; surfaces in System Settings → Login Items
- **SwiftData**: structured persistence for the decision log + per-network preferences; `ModelActor` for safe agent-side writes
- **OSLog / `Logger`**: structured logging that survives crashes and is queryable via `log show` / Console.app
- **Distribution**: Developer ID Application cert + hardened runtime + `xcrun notarytool` + `xcrun stapler` + `create-dmg`; optional Homebrew Cask
- **Testing**: Swift Testing for logic + XCTest for UI/performance only

**Do NOT use:** `altool` (decommissioned Nov 2023), `SMLoginItemSetEnabled` / `SMJobBless` (deprecated), `SCNetworkReachability` (deprecated), `airport` CLI (removed in macOS 15), `com.apple.developer.networking.wifi-info` entitlement (iOS-only), pure-SwiftPM app target, Combine for new code, swift-log.

### Expected Features

**Must have (table stakes):**
- Live RSSI of current network + nearby known networks
- Connectivity health check on current network (ping + DNS via Network framework)
- Hysteresis (delta threshold + dwell timer) on the switch decision itself
- Enable/disable auto-switching + "pause for N minutes" panic button
- Menubar item (SSID + status glyph + quick controls) + main window
- Background operation when window is closed (LSUIElement-only or LaunchAgent)
- Graceful Location Services permission onboarding
- Captive portal *avoidance* (not login — out of scope per PROJECT.md)
- Visible hysteresis thresholds in settings (read-only OK for v1)
- Signed + notarized `.app`

**Should have (differentiators — portfolio value):**
- Compound score (RSSI + health + band-preference) instead of RSSI-only
- Two-axis hysteresis (N dB better AND for T seconds)
- Transparent, structured decision log including *rejected* switches with reasons
- Live scoring panel (sortable table of every nearby known network's current score)
- Per-network policy overrides (prefer / avoid / never-auto-join)
- Composite-score curve graph (SwiftUI Charts)
- Snapshot a "WiFi situation" to a single file

**Defer (v2+):**
- Lightweight throughput sample beyond ping/DNS
- Editable hysteresis thresholds
- Notification on switch (opt-in)
- Homebrew Cask, Sparkle auto-update, CSV/JSON export
- Auto-tuning of hysteresis from observed flap rate
- Time-series chart with deep history, plugin system, multi-interface support

**Explicit anti-features:** Captive portal auto-login, joining unknown/open networks, profile sync (iCloud Keychain handles it), third-party speed tests, telemetry, App Store distribution, BSS-level roaming (the driver handles it), heatmaps, spectrum analysis, per-app routing.

### Architecture Approach

Two-process design — GUI + background agent — connected via NSXPCConnection over a launchd MachServices endpoint. Inside the agent, one Swift actor per concern (Scan / Health / Decision / Switch / Persistence) feeds events into a single `CoordinatorActor` that owns the state machine. The scoring and hysteresis math live in a pure-Swift `Shared/Algorithms/` module with zero framework imports — the testable core and spine of the portfolio story.

**Scope-vs-architecture tension:** ARCHITECTURE.md recommends the full split as the production shape. For a personal + portfolio scope, the architecturally pure path is overkill *until the GUI exists and has shaped the IPC protocols*. **Recommendation: defer the agent-split to a late phase, and run as a single LSUIElement-only process for v1.**

**Major components:**
1. **GUI process** — `MenuBarExtra` + main window + Settings scene, bound to `@Observable` `AppState`
2. **Background agent** (eventual) — owns `CoordinatorActor`, all actors, CW singleton, SwiftData store
3. **`ScanActor`** — serializes all CoreWLAN calls; subscribes to `scanCacheUpdated`; 10s minimum gap between active scans
4. **`HealthActor`** — `NWPathMonitor` + cadenced ICMP/UDP/DNS probes; emits `HealthSample` events
5. **`DecisionActor`** — consumes scan + health; maintains per-BSSID EWMAs; runs hysteresis + scoring; emits `Decision { stay | switchTo(SSID) }`
6. **`SwitchActor`** — performs `CWInterface.associate(...)`; cooldown enforcement; outcome reporting
7. **`PersistenceActor`** — SwiftData `ModelActor`
8. **`ConfigStore`** — JSON in App Group; agent file-watches for live edits
9. **Pure `Shared/Algorithms/`** — EMA, ScoringEngine, Hysteresis; zero framework imports

**State machine:** OFF ⇄ STEADY ⇄ DEGRADED → SWITCHING → COOLDOWN → STEADY. Adaptive scan cadence per state (60-120s STEADY, 10-15s DEGRADED, suspended SWITCHING, 30s cooldown).

**Hysteresis (the project's signature):** Three layers — EMA smoothing (α≈0.3), threshold bands (e.g., `goodEnough=-67 dBm`, `tooWeak=-75 dBm`), dwell timers (`degradeDwell=10s`, `candidateDwell=8s`, `switchMargin≥15 score points`, `postSwitchCooldown=30s`). All five numbers belong in `config.json` so they are visible to the user.

### Critical Pitfalls

1. **SSID/BSSID returns nil without Location Services authorization** — gates everything. Mitigation: explicit `CLLocationManager.requestAlwaysAuthorization()`, all three `NSLocation*UsageDescription` keys with distinct non-empty strings, ship as a real `.app` bundle, call `startUpdatingLocation()` briefly after auth (community-reported Sonoma quirk), in-app remediation banner with deep-link to System Settings. **Phase 1 work, not polish.**

2. **Hardened runtime / notarization rejection** — discovered-late failures are panic-inducing. Mitigation: disable App Sandbox (incompatible with reliable `associate()`; PROJECT.md excludes App Store), enable hardened runtime, minimal entitlements (`com.apple.security.network.client` only), set up `xcrun notarytool` pipeline in Phase 1, test on a clean Mac. **Notarize early.**

3. **Naive "highest RSSI wins" causes flapping — the very problem the app exists to solve.** Mitigation: multi-layer hysteresis baked in from Phase 3 before any switching code exists. A 1-hour soak test in a stable multi-AP environment should show zero switches.

4. **`SMAppService` "Background item added" notification surprises** — repeat notifications + users disabling agent breaks the app. Mitigation: use `SMAppService`, only call `register()` if `.status != .enabled`, onboarding screen explains the notification *before* it appears, in-app toggle with live status reflection, code-sign helper identically.

Additional critical pitfalls in PITFALLS.md: over-scanning kills battery + degrades user traffic, captive portal auto-join, 2.4 vs 5 GHz on the same SSID, switching mid-call, invisible switches breaking trust, overriding user's manual choice.

## Implications for Roadmap

Architecture's "Suggested Build Order" (Steps 1-9) is the spine. Its core insight: **Steps 1-5 are all single-process work** with no XPC complexity and no SMAppService friction. The developer learns CoreWLAN, the Network framework, the radio's quirks, and the hysteresis math before paying any process-split tax. A roadmap that front-loads IPC/SMAppService work will burn time on plumbing while still uncertain about the algorithm. **Front-load the algorithm, defer the architecture purity.**

### Phase 1: Foundations — Permissions, Signing, Read-only CoreWLAN Inspector

**Rationale:** Three things must work on real hardware before any feature code: (a) Location Services auth produces non-nil SSIDs, (b) notarization pipeline succeeds end-to-end on a clean Mac, (c) CoreWLAN reads work from a properly bundled `.app`. Pitfalls 1, 2, 7 all require this phase.

**Delivers:** Minimal SwiftUI `.app` that requests Location auth, performs a CoreWLAN scan, prints current SSID/BSSID/RSSI + nearby networks, subscribes to `scanCacheUpdated` events, ships through `xcrun notarytool` (signed, notarized, stapled, runs on a fresh Mac).

**Addresses:** "Detect saved networks + scan for in-range matches" + "Location Services permission flow" + "Signed + notarized build" (all P1).

**Avoids:** Pitfalls 1, 2, 7. Verified by clean-install test on a different Mac.

### Phase 2: Health Probes + BSSID-keyed Data Model

**Rationale:** Second half of "what data do we have?" — independent of CoreWLAN. Data model must key by `(SSID, BSSID, band, channel)` from day one to avoid Pitfall 5; retrofitting BSSID-keying is painful.

**Delivers:** `HealthActor` using `NWPathMonitor` + UDP-to-gateway latency + DNS lookup + captive.apple.com probe. Live latency/loss/DNS-success readouts. Canonical `(SSID, BSSID, band, channel)` data structures.

**Uses:** Network framework.

**Avoids:** Pitfall 5 (same-SSID-multiple-bands); partial Pitfall 4 (captive detection + per-SSID flag).

### Phase 3: Pure Scoring + Hysteresis Engine (Algorithms Library, Synthetic Inputs)

**Rationale:** *The most important phase.* Build EMA smoother, threshold bands, dwell timers, compound score in a framework-free Swift module with comprehensive Swift Testing parameterized tests using synthetic inputs. The most subtle code in the project deserves to exist before it is wired to the radio. Pitfall 3 (flapping) is prevented by construction. Portfolio centerpiece: the algorithm is testable, reviewable, explainable in isolation.

**Delivers:** `Shared/Algorithms/` SwiftPM library — `EMA.swift`, `ScoringEngine.swift`, `Hysteresis.swift` — with signature `(scan, health, prefs, prior) -> Decision`. Replay test suite. `Config` struct exposing all hysteresis constants.

**Implements:** Architecture's "Pattern 5: Pure-logic core, side-effecting shell."

**Avoids:** Pitfall 3 by construction.

### Phase 4: Live Decision Engine, Observe-only Mode

**Rationale:** Wire Phases 1+2+3 together into a running loop that emits Decisions but **does not yet actually switch**. Decision log is born here. Run for a day or two against developer's real environment to validate.

**Delivers:** Single-process app that scans, probes, scores, and emits `Decision` events to OSLog and an in-memory ring buffer. State machine implemented and observable. Adaptive scan cadence live.

**Avoids:** Pitfall 2 (adaptive cadence), Pitfall 9 (decisions instrumented from this phase onward).

### Phase 5: Active Switching + Manual-Join Respect + Pause Controls

**Rationale:** First destructive operation. Manual-join detection must ship together with auto-switching or Pitfall 10 is guaranteed. "Pause for N minutes" is a Pitfall 8 mitigation.

**Delivers:** `SwitchActor.associate(...)` with cooldown + link-change confirmation timeout. Manual-join detection via `linkDidChange` correlated with absent app-initiated associates. "Manual hold" timer (default 10 min) with visible UI countdown. Auto-switch toggle + "pause for N minutes" hotkey. Active-traffic awareness raises threshold during high bidirectional UDP.

**Avoids:** Pitfall 8 (mid-call), Pitfall 10 (manual override), partial Pitfall 4 (captive scoring penalty).

### Phase 6: GUI MVP — MenuBarExtra + Main Window + Decision Log View

**Rationale:** UI is iterative and shouldn't block on infrastructure. Architecture explicitly recommends doing this *before* the agent-split — XPC protocols are easier to design after `@Bindable` mental model has shaped the GUI's needs. Decision log moves from in-memory to first-class view. First demoable portfolio artifact.

**Delivers:** SwiftUI `MenuBarExtra` (current SSID + status glyph + quick toggle + pause + open-main-window + quit), main window (live current-network + nearby-known-networks scoring table + scrollable decision log filtered by switches/rejections/all), Settings scene (read-only thresholds, captive flags, per-network preferences). Talks directly to in-process actors — no XPC. App is LSUIElement.

**Implements:** All P1 UI features.

**Avoids:** Pitfall 9 (decision log front-and-center).

### Phase 7: Background Persistence — SMAppService LoginItem (decision point) + SwiftData

**Rationale:** Adds true background operation. **Decision point on architecture path:** simpler "login-item with LSUIElement" pattern (the main app stays running as LSUIElement-only, registered via `SMAppService.loginItem`) is genuinely viable for v1 and avoids XPC entirely; the architecturally pure agent + GUI split via XPC is the long-term shape. **Recommendation: ship the simpler login-item path for v1.** Architecture-purity gain doesn't outweigh complexity for personal/portfolio scope until the GUI process itself proves it needs to be separable from the monitoring loop. Treat XPC agent-split as optional Phase 8.

**Delivers:** `SMAppService.loginItem` with idempotent register/unregister logic. Onboarding screen explaining "Background item added" *before* it appears. SwiftData `PersistenceActor` with decision-log schema; paged queries from disk; per-network preferences persist. Rolling-window deletion of decisions older than 90 days.

**Avoids:** Pitfall 6 (background-item surprises) via SMAppService + idempotent registration + onboarding.

### Phase 8 (optional, defer until validated): XPC Agent Split

**Rationale:** Only justified if v1 reveals a concrete reason the GUI process cannot also be the monitoring loop. Architecture purity alone is not enough.

**Delivers:** `auto-wifi-agent` target at `Contents/MacOS/auto-wifi-agent`, `AgentProtocol` / `GUIObserverProtocol` XPC interfaces, `AgentClient` GUI-side proxy with reconnect logic, config in App Group container with `DispatchSource` file-watching.

### Phase 9: Polish + Distribution

**Rationale:** Last because distribution work is well-trodden. Notarization pipeline (Phase 1) has been exercised continuously by this point.

**Delivers:** `create-dmg` DMG, Homebrew Cask formula (personal tap or homebrew/cask submission), README + portfolio writeup, optional Sparkle 2.x auto-update, snapshot-export feature, opt-in notification-on-switch, CSV/JSON decision-log export, v1.0 release.

### Phase Ordering Rationale

- **Dependency-driven:** Location auth and notarization (Phase 1) unblock everything else. Data model + health probes (Phase 2) and pure algorithm (Phase 3) concentrate technical risk upstream. Switching (Phase 5) intentionally deferred behind observe-only (Phase 4). UI (Phase 6) before any process-split so XPC protocols are informed by real GUI consumption.
- **Architecture-aligned:** Mirrors ARCHITECTURE.md's Steps 1-9 exactly. Steps 1-5 single-process; developer learns the platform before paying the process-split tax.
- **Pitfall-driven:** Each phase is the *earliest* at which its target pitfalls can be mitigated. Pitfalls 1 & 7 cannot be deferred past Phase 1. Pitfall 3 prevented by construction in Phase 3. Pitfall 10 ships with first switching code in Phase 5. Pitfall 9 instrumented from Phase 4, surfaced in Phase 6.
- **Demo-driven:** Phase 4 produces logs that read like the portfolio story. Phase 6 produces a screenshot-worthy GUI. Phases 7+ are infrastructure that waits for evidence it is needed.

### Phase 1 Decision Points (to resolve during requirements / Phase 1 planning)

1. **`SMAppService.loginItem` (LSUIElement-only single process) vs `SMAppService.agent` (separate agent + GUI with XPC).** STACK.md flags login-item as a viable phase-0 alternative; ARCHITECTURE.md recommends full agent split as production. **Recommendation: login-item path for v1.**
2. **XPC split timing.** **Recommendation: defer XPC to Phase 8 (optional), not v1.** Tied to decision 1.
3. **Throughput sampling in v1?** FEATURES.md marks as P2; PITFALLS.md warns RFC 6349 multi-second transfers are too heavy. **Recommendation: ship v1 with ping + DNS health only.**
4. **Editable hysteresis thresholds in v1 or read-only?** FEATURES.md marks editable as P2. **Recommendation: read-only display of defaults in v1.**

### Research Flags

Phases likely needing deeper research during planning:

- **Phase 1:** YES — five empirical questions from `ARCHITECTURE.md` "Open Questions" need hardware-in-hand answers: CoreWLAN scan rate-limit on macOS 14.4+, `associate(toNetwork:password:)` with `nil` password for Enterprise, `scanCacheUpdated` reliability when not-frontmost, SMAppService macOS 14.4+ Info.plist requirements (error-125 reports), ICMP-equivalent via `NWConnection` UDP-to-gateway vs raw-socket entitlements.
- **Phase 3:** Probably YES — starting values for hysteresis constants deserve a literature-and-empirical review.
- **Phase 7:** YES — SMAppService quirks on macOS 14.4+, code-signing the embedded helper, idempotent registration.
- **Phase 8 (if pursued):** YES — NSXPCConnection lifecycle (reconnect, dropped-proxy detection).

Phases with standard patterns (can skip research-phase):

- **Phase 2:** Standard NWPathMonitor + NWConnection.
- **Phase 5:** `CWInterface.associate(...)` and `linkDidChange` well-documented.
- **Phase 6:** SwiftUI + MenuBarExtra patterns well-established.
- **Phase 9:** `xcrun notarytool` + `create-dmg` + Homebrew Cask well-trodden; pipeline already validated in Phase 1.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Apple docs + Apple-engineer forum threads + 2026 community sources converge on the same modern stack. MEDIUM sub-item: `CWInterface.associate(...)` reliability on macOS 14+. |
| Features | HIGH | Tool landscape well-mapped; roaming standards literature directly informs must-have/differentiator split. MEDIUM only for closed-source competitor UX. |
| Architecture | MEDIUM-HIGH | Process model + IPC + actors: HIGH (textbook Apple patterns). CoreWLAN scan cadence specifics: MEDIUM (precise rate limits poorly documented). Hysteresis algorithm: HIGH. |
| Pitfalls | HIGH | macOS permission/notarization backed by Apple docs + forum reports. Roaming/hysteresis pitfalls backed by Cisco/Juniper/Meraki + WiFi literature. MEDIUM on exact CoreWLAN behavior on 14.4+. |

**Overall confidence:** HIGH. The four researchers converged independently on the same critical insights (Location auth as Phase 1, real `.app` bundle from day one, `SMAppService` as the modern path, early notarization, multi-layer hysteresis, RSSI-plus-health compound score, post-association captive probe, decision log as portfolio centerpiece). That cross-document consensus is the highest-signal evidence available in this kind of research.

### Gaps to Address

- **Empirical CoreWLAN behavior on macOS 14.4+:** scan rate-limits, `scanCacheUpdated` reliability not-frontmost, `associate(...)` with `nil` for Enterprise SSIDs. → Phase 1 spike, document findings in `.planning/research/PHASE_1.md` before committing to algorithm constants.
- **Default hysteresis constant values:** starting values (RSSI band -67/-75 dBm; α=0.3; degradeDwell=10s; candidateDwell=8s; switchMargin≥15 points; cooldown=30s) need calibration. → Ship Phase 4 in observe-only; tune from real decision-log data before enabling Phase 5 switching.
- **`SMAppService` macOS 14.4+ specifics:** sporadic error-125 reports without root-cause. → Dedicated investigation at start of Phase 7; fallback is the v1-recommended `SMAppService.loginItem` path.
- **Manual-join detection heuristic precision:** correlating `linkDidChange` with absent app-initiated associates has timing edge cases. → Phase 5 needs dedicated test scenario.
- **Captive portal flag persistence:** enterprise networks sometimes broadcast captive *and* non-captive variants. → Track flag per `(SSID, BSSID)` pair, not per SSID alone.

---
*Research completed: 2026-05-12*
*Ready for roadmap: yes*
