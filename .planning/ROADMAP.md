# Roadmap: auto-wifi

## Overview

auto-wifi is a native macOS GUI that intelligently switches between known WiFi networks based on a compound score (smoothed RSSI + measured health) with multi-layer hysteresis, while transparently logging every decision (including switches considered and rejected). v1 is delivered as a single-process LSUIElement `.app` with an embedded login-item for background operation. The roadmap front-loads the two front-line risks (Location Services authorization + notarization pipeline), then builds the testable algorithm in isolation, validates it in observe-only mode against the developer's real environment, and only then enables destructive switching. UI lands after the engine is trusted; persistence and the login item follow once the decision schema is real; distribution closes the loop. The architecturally-pure XPC agent split (REQUIREMENTS.md ARCH-01) is deferred to v2 — for personal/portfolio scope, the simpler login-item-with-LSUIElement pattern is enough.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundations** - Signed/notarized `.app` shell with Location Services auth, CoreWLAN read of known networks, and remediation banner
- [ ] **Phase 2: Scanning + Health Probes + BSSID Data Model** - Adaptive WiFi scanning, ping/DNS health probes, captive-portal detection, BSSID-keyed canonical data structures
- [ ] **Phase 3: Pure Scoring + Hysteresis Engine** - Framework-free Swift `Algorithms` library implementing EMA, compound scoring, multi-layer hysteresis with full Swift Testing coverage
- [ ] **Phase 4: Live Decision Loop (Observe-only)** - End-to-end engine producing `Decision` events to OSLog + in-memory log, with a state-machine view and an "Observe" default mode
- [ ] **Phase 5: Active Switching + Manual-Join Respect** - `CWInterface.associate(...)` with link-change confirmation, manual-join detection, pause control, and active-traffic awareness
- [ ] **Phase 6: GUI MVP (MenuBarExtra + Main Window + Settings)** - Polished SwiftUI surfaces: menubar item, live scoring dashboard, filterable decision log, read-only thresholds + per-network preferences
- [ ] **Phase 7: Background Persistence (Login Item + SwiftData)** - `SMAppService.loginItem` background operation with onboarding, SwiftData decision log with paging + 90-day rollover, persisted per-network preferences
- [ ] **Phase 8: Distribution** - `make release` builds, signs, hardens, notarizes, staples, and packages a DMG; README explains the algorithm and install path

## Phase Details

### Phase 1: Foundations
**Goal**: A signed, notarized `.app` runs on a clean Mac, gets Location Services authorization, and prints current SSID + nearby known networks via CoreWLAN
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: FOUND-01, FOUND-02, FOUND-03, FOUND-04, FOUND-05
**Success Criteria** (what must be TRUE):
  1. User downloads and launches the `.app` on a fresh Mac (never run before) and Gatekeeper allows it to open without security warnings blocking launch
  2. On first launch, user sees an explanatory prompt that explains why WiFi inspection needs Location Services, then receives the system Location authorization prompt
  3. After granting authorization, user sees the current SSID/BSSID/RSSI plus a list of nearby known WiFi networks populated from CoreWLAN
  4. If the user denies or later revokes Location Services authorization, the app shows a remediation banner with a one-click deep-link to System Settings → Privacy & Security → Location Services
  5. `make notarize` (or equivalent) completes end-to-end: Developer ID signing, hardened runtime, `xcrun notarytool submit --wait`, and `xcrun stapler staple` all succeed against a release archive
**Plans**: TBD

### Phase 2: Scanning + Health Probes + BSSID Data Model
**Goal**: The app continuously collects everything it needs to decide — adaptive scans of all nearby known networks, live health metrics for the current network, captive-portal flags, and a canonical `(SSID, BSSID, band, channel)` data model
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: SCAN-01, SCAN-02, SCAN-03, SCAN-04, HEAL-01, HEAL-02, HEAL-04
**Success Criteria** (what must be TRUE):
  1. User can open a debug view showing the live RSSI of every nearby known network refreshing as the OS publishes `scanCacheUpdated` events, without the user pressing a "rescan" button
  2. User can see the current network's live ping latency, DNS lookup success rate, and packet loss (computed by the in-app Network-framework probes — no third-party services)
  3. When the user joins a captive portal network (e.g., a coffee shop), the app probes `captive.apple.com` after association and stores a `captive=true` flag on that `(SSID, BSSID)` pair visible in the debug view
  4. The same SSID broadcast on 2.4 GHz and 5 GHz appears as two distinct candidates in the data model (different BSSIDs, different bands), and the UI never duplicates the SSID row when aggregating
  5. The app stops running active health probes when the system reports the link is on a tethered cellular / metered connection (via `NWPathMonitor.isExpensive` / `isConstrained`)
**Plans**: TBD

### Phase 3: Pure Scoring + Hysteresis Engine
**Goal**: A framework-free Swift `Algorithms` library encodes the project's signature logic — EMA smoothing, compound score, threshold bands, dwell timers, post-switch cooldown — and is fully covered by Swift Testing using synthetic inputs, before any radio I/O touches it
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: DEC-01, DEC-02, DEC-03, DEC-04, DEC-05, HEAL-03
**Success Criteria** (what must be TRUE):
  1. `swift test` against the `Algorithms` SwiftPM target passes a comprehensive Swift Testing suite that replays synthetic scan + health sequences (steady, oscillating-near-equal, sustained-degradation, captive-flagged, RSSI-noise) and asserts the engine never flaps and always explains rejections
  2. The `Algorithms` module declares zero framework imports (`grep -RE "import (CoreWLAN|Network|Foundation\\.NW|AppKit|SwiftUI)" Shared/Algorithms/` returns nothing) — the pure-logic shell is structurally enforced
  3. For every evaluation cycle, the engine emits a structured `Decision` event including the considered candidates, their scores, and a human-readable reason — including for switches considered and rejected (e.g., "rejected Foo-5G: only +6 dB improvement, below 15-point switch margin")
  4. Hysteresis is multi-layered and visible: EMA α, RSSI band (`goodEnough` / `tooWeak`), `degradeDwell`, `candidateDwell`, `switchMargin`, and `postSwitchCooldown` all live in a `Config` struct loaded from JSON, and a developer-visible view in the app renders the current values
  5. Networks flagged captive (from Phase 2) receive a large negative score modifier so the engine never recommends switching to them in synthetic tests
**Plans**: TBD

### Phase 4: Live Decision Loop (Observe-only)
**Goal**: The engine runs continuously against the developer's real WiFi environment, producing realistic `Decision` events to OSLog and an in-memory ring buffer — but defaults to "Observe" mode and performs no actual association calls, so the algorithm can be validated against ground truth before any destructive operation
**Mode:** mvp
**Depends on**: Phase 3
**Requirements**: OBS-01, OBS-02, OBS-03
**Success Criteria** (what must be TRUE):
  1. With auto-switch mode set to "Observe" (the default on first launch), the app runs the full scan → score → decide loop continuously and writes structured `Decision` entries to OSLog and an in-memory ring buffer — and never calls `CWInterface.associate(...)`
  2. User can flip between `OFF`, `Observe`, and `ON` from a visible mode-switch control; on first launch the control is in `Observe`
  3. The app's state-machine state (`OFF` / `STEADY` / `DEGRADED` / `SWITCHING` / `COOLDOWN`) is visible in the menubar tooltip or developer view and updates in response to live scan and health data
  4. After running for a continuous hour in a stable multi-AP environment with auto-switch in `Observe`, the in-memory decision log contains zero "would have switched" entries (i.e., hysteresis is preventing flap in the real world, not just in synthetic tests)
**Plans**: TBD

### Phase 5: Active Switching + Manual-Join Respect
**Goal**: When the user enables auto-switch, the app actually associates to the chosen better network — but respects the user's manual choices, raises the bar during active calls, confirms link transitions before declaring success, and exposes a one-click "Pause for N minutes" panic button
**Mode:** mvp
**Depends on**: Phase 4
**Requirements**: SW-01, SW-02, SW-03, SW-04, SW-05
**Success Criteria** (what must be TRUE):
  1. With auto-switch set to `ON`, when the current network degrades and a meaningfully better known network is in range, the app calls `CWInterface.associate(...)` with credentials from the System Keychain and the user observes the WiFi icon switching to the new SSID
  2. When the user manually picks a different network from the macOS WiFi menu, the app detects the link change as not-app-initiated, enters a "Manual hold" mode for 10 minutes (configurable), and does not override that choice — and the hold countdown is visible
  3. User can click a "Pause auto-switching for N minutes" control reachable in one click (from the existing mode/state surface in Phase 4 — the menubar item ships in Phase 6) and the app honors the pause for the chosen duration
  4. When sustained high bidirectional UDP traffic indicates an active call or large transfer, the switch threshold rises measurably (visible as rejected-switch entries in the decision log explaining "active traffic detected, raised margin")
  5. Every `associate(...)` attempt waits up to a configurable timeout (default ~15s) for a confirming `linkDidChange`; failures are logged with a reason and counted against the candidate's recent-failure penalty
**Plans**: TBD

### Phase 6: GUI MVP (MenuBarExtra + Main Window + Settings)
**Goal**: The app becomes portfolio-shaped — a SwiftUI MenuBarExtra with live status, a main window that shows the current network, a sortable scoring table of nearby known networks, a filterable decision log front-and-center, and a Settings scene for read-only thresholds + per-network preferences
**Mode:** mvp
**Depends on**: Phase 5
**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05, UI-06
**Success Criteria** (what must be TRUE):
  1. User sees a `MenuBarExtra` item showing the current SSID, a status glyph (steady / degraded / switching / paused), and quick toggles for auto-switch enable and pause-for-N-minutes — all reachable without opening the main window
  2. User opens the main window from the menubar and sees the current network with live RSSI, latency, DNS success rate, and computed score updating continuously
  3. User sees a sortable table of every nearby known network with its current score and the inputs feeding the score (smoothed RSSI, health, captive flag, band, per-network preference)
  4. User sees a chronological decision log with filter toggles (`all` / `switches only` / `rejected switches` / `errors`) and every entry explains its reason in plain language
  5. User opens the Settings scene and sees the current hysteresis thresholds (read-only display in v1) plus controls to set per-network preferences (prefer / avoid / never-auto-join)
  6. The app runs as `LSUIElement` — no Dock icon by default — and the main window is reachable only from the menubar
**Plans**: TBD
**UI hint**: yes

### Phase 7: Background Persistence (Login Item + SwiftData)
**Goal**: The app runs continuously in the background after login without the main window being open, the decision log survives across launches in SwiftData (with a 90-day rollover), per-network preferences persist, and the user is warned about the "Background item added" notification before macOS shows it
**Mode:** mvp
**Depends on**: Phase 6
**Requirements**: BG-01, BG-02, BG-03, BG-04, BG-05
**Success Criteria** (what must be TRUE):
  1. After user enables the background service from the onboarding screen, the app appears in System Settings → General → Login Items under its own name, starts after a reboot without the user opening the app, and continues to make decisions while the main window is closed
  2. Before macOS shows the "Background item added" system notification, the user has seen an in-app onboarding screen with a screenshot explaining exactly what that notification will look like and why it is expected
  3. User closes the app, relaunches it the next day, and sees the decision log from yesterday's session in the main window — paged from disk, not loaded all at once, so the UI stays responsive even with thousands of entries
  4. User sets per-network preferences (e.g., "never-auto-join GuestWiFi") and confirms they persist across a restart and continue to influence scoring
  5. Decision log entries older than 90 days are automatically purged on a recurring schedule (verifiable by inserting fixture entries with backdated timestamps and observing them disappear)
**Plans**: TBD
**UI hint**: yes

### Phase 8: Distribution
**Goal**: A single `make release` target produces a signed, hardened-runtime, notarized, stapled `.app` plus a DMG for distribution, accompanied by a README that explains what the app is, why it exists, how the hysteresis algorithm works, and how to install it
**Mode:** mvp
**Depends on**: Phase 7
**Requirements**: DIST-01, DIST-02
**Success Criteria** (what must be TRUE):
  1. Running `make release` (or the documented equivalent) from a clean checkout produces a `.app` and a `.dmg` artifact in a known output directory, in a single command, with no manual Xcode UI steps
  2. The notarization pipeline (already validated in Phase 1) succeeds end-to-end on the release artifact: `xcrun notarytool submit --wait` reports `Accepted` and `xcrun stapler validate` confirms the ticket is stapled to both the `.app` and the `.dmg`
  3. A user who has never seen the app downloads the DMG on a clean Mac, drags the `.app` to Applications, double-clicks it, and the app opens without Gatekeeper warnings
  4. The repository root contains a README that (a) explains what auto-wifi is, (b) explains the hysteresis algorithm at a level a recruiter could follow, (c) points to the decision log as the portfolio storytelling artifact, and (d) gives step-by-step install instructions
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundations | 0/TBD | Not started | - |
| 2. Scanning + Health Probes + BSSID Data Model | 0/TBD | Not started | - |
| 3. Pure Scoring + Hysteresis Engine | 0/TBD | Not started | - |
| 4. Live Decision Loop (Observe-only) | 0/TBD | Not started | - |
| 5. Active Switching + Manual-Join Respect | 0/TBD | Not started | - |
| 6. GUI MVP (MenuBarExtra + Main Window + Settings) | 0/TBD | Not started | - |
| 7. Background Persistence (Login Item + SwiftData) | 0/TBD | Not started | - |
| 8. Distribution | 0/TBD | Not started | - |

---
*Roadmap created: 2026-05-12*
*Granularity: standard*
*Mode: mvp*
*Coverage: 39/39 v1 requirements mapped*
