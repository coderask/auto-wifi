# Requirements: auto-wifi

**Defined:** 2026-05-12
**Core Value:** When multiple known WiFi networks are in range, the user is always on the genuinely best one — and never stranded on a dead or weak network because macOS was slow to switch.

## v1 Requirements

Requirements for initial release. Each maps to a roadmap phase.

### Foundations

- [ ] **FOUND-01**: App is distributed as a signed and notarized `.app` bundle (Developer ID + hardened runtime + `xcrun notarytool` + stapled), and installs and runs on a clean Mac without security prompts blocking launch
- [ ] **FOUND-02**: App requests Location Services authorization on first launch and explains *why* (required by macOS for SSID/BSSID visibility)
- [ ] **FOUND-03**: App detects when Location Services authorization is missing or revoked, and shows a remediation banner with a deep-link to System Settings → Privacy & Security → Location Services
- [ ] **FOUND-04**: App reads the list of system-saved (known) WiFi networks and joins it against live scan results so only known networks appear as switch candidates
- [ ] **FOUND-05**: App targets macOS 14+ (Sonoma) and uses Swift 6.2 / SwiftUI / CoreWLAN / Network framework — no deprecated APIs (`altool`, `SMJobBless`, `airport`, `SCNetworkReachability`)

### Scanning & Data Model

- [ ] **SCAN-01**: App performs adaptive periodic scans of nearby WiFi networks (longer interval in steady state, faster when degraded)
- [ ] **SCAN-02**: App subscribes to CoreWLAN's `scanCacheUpdated` events so scan data refreshes when the system already has fresh data — without forcing extra active scans
- [ ] **SCAN-03**: Internal data model keys candidates by `(SSID, BSSID, band, channel)` so the same SSID on 2.4 GHz vs 5 GHz vs different APs are distinct candidates
- [ ] **SCAN-04**: App caches scan results with a TTL so the UI never blocks on a fresh scan

### Health Probing

- [ ] **HEAL-01**: App measures the current connection's health continuously using ping/UDP-to-gateway latency and DNS lookup success — not just signal strength
- [ ] **HEAL-02**: App detects captive portals by probing `http://captive.apple.com/hotspot-detect.html` after association and learns a "captive" flag per `(SSID, BSSID)`
- [ ] **HEAL-03**: Known captive networks are penalized in scoring so the app does not auto-switch to them
- [ ] **HEAL-04**: Health probes use the Network framework and respect cellular/metered links (no probing if the user is on tethered cellular)

### Decision Engine (Algorithm)

- [ ] **DEC-01**: A pure-Swift `Algorithms` library (zero framework imports) implements EMA smoothing, scoring, and hysteresis with full Swift Testing coverage using synthetic inputs
- [ ] **DEC-02**: Each candidate gets a composite score combining smoothed RSSI, measured health, captive flag, band preference, and per-network user preference
- [ ] **DEC-03**: Multi-layer hysteresis: threshold bands (good-enough RSSI vs too-weak RSSI), dwell timers (sustained-degradation window before considering a switch, sustained-better-candidate window before switching), and post-switch cooldown to prevent flapping
- [ ] **DEC-04**: Hysteresis constants (RSSI thresholds, EMA α, dwell windows, switch margin, cooldown) are surfaced as configuration; v1 is read-only in the UI but the values are visible to the user
- [ ] **DEC-05**: The engine emits structured `Decision` events for *every* evaluation cycle, including switches considered and rejected with the reason (e.g., "candidate `Foo-5G` rejected: only +6 dB improvement, below 15-point switch margin")

### Live Decision Loop (Observe-only)

- [ ] **OBS-01**: Engine runs continuously, producing decisions but emitting them only to the in-memory log and OSLog — no actual association calls until OBS-02 ships
- [ ] **OBS-02**: A clear "Auto-switch: OFF / Observe / ON" mode switch in the UI defaults to "Observe" on first launch so the user can validate decisions before letting the app act
- [ ] **OBS-03**: State machine `OFF ⇄ STEADY ⇄ DEGRADED → SWITCHING → COOLDOWN → STEADY` is implemented and the current state is shown in the menubar tooltip

### Switching & User Respect

- [ ] **SW-01**: When auto-switch is ON, the app actively associates to the chosen better network using `CWInterface.associate(...)` with credentials from the System Keychain
- [ ] **SW-02**: Manual-join detection: when the user manually picks a network (a link change not initiated by the app), the app enters a "manual hold" mode for a default 10-minute window and will not override that choice
- [ ] **SW-03**: A "Pause auto-switching for N minutes" control is reachable in one click from the menubar
- [ ] **SW-04**: Active-traffic awareness: when bidirectional traffic indicates a live call or large transfer, the switch threshold is raised so the app does not interrupt the user mid-stream
- [ ] **SW-05**: After every association attempt, the app verifies the link change actually succeeded within a timeout; failures are logged and counted against the candidate

### GUI (MenuBarExtra + Main Window)

- [ ] **UI-01**: MenuBarExtra shows current SSID, a status glyph indicating state (steady / degraded / switching / paused), and quick toggles for auto-switch enable + pause
- [ ] **UI-02**: Main window shows the current network with live RSSI, latency, DNS health, and computed score
- [ ] **UI-03**: Main window shows a sortable table of all nearby *known* networks with their current scores and the inputs feeding each score
- [ ] **UI-04**: Main window shows a chronological decision log (filterable: all / switches only / rejected switches / errors) with each entry explaining the reason in plain language
- [ ] **UI-05**: Settings scene shows the current hysteresis thresholds (read-only in v1) and lets the user set per-network preferences (prefer / avoid / never-auto-join)
- [ ] **UI-06**: App is `LSUIElement` (no Dock icon by default); the main window is reachable from the menubar

### Background Operation & Persistence

- [ ] **BG-01**: App registers itself as a login item via `SMAppService.loginItem` so it runs in the background after login without the main window being open
- [ ] **BG-02**: Onboarding screen explains the macOS "Background item added" notification *before* it appears, with a screenshot showing what the user will see
- [ ] **BG-03**: Decision log persists across launches in SwiftData; the UI pages large logs from disk rather than loading all rows
- [ ] **BG-04**: Per-network preferences (prefer / avoid / never-auto-join, captive flag) persist across launches in SwiftData
- [ ] **BG-05**: Old decision-log rows are rolled off after 90 days

### Distribution

- [ ] **DIST-01**: A single `make release` (or equivalent) target builds, signs, hardens, notarizes, and staples a release `.app` — and produces a DMG for distribution
- [ ] **DIST-02**: Project includes a README that explains what the app is, why it exists, how the hysteresis algorithm works (decision-log is the portfolio storytelling artifact), and how to install

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Throughput & Tuning

- **THR-01**: Lightweight throughput sampling on the current connection (in addition to ping/DNS)
- **TUNE-01**: Editable hysteresis thresholds in the GUI (currently read-only display only)
- **TUNE-02**: Auto-tuning of hysteresis from observed flap rate

### Polish & Distribution

- **POL-01**: Opt-in user notification when the app switches networks (banner with reason)
- **POL-02**: Sparkle auto-update integration
- **POL-03**: Homebrew Cask formula in a tap or homebrew/cask submission
- **POL-04**: CSV / JSON export of the decision log
- **POL-05**: "Snapshot WiFi situation to file" diagnostic export
- **POL-06**: SwiftUI Charts visualization of score over time

### Architecture

- **ARCH-01**: Split into separate GUI process + `SMAppService.agent` background helper connected via NSXPCConnection (currently single-process / login-item)

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| iOS / iPadOS / Windows / Linux support | Platform-specific frustration; iOS WiFi APIs are heavily restricted; cross-platform adds enormous complexity for no portfolio gain |
| Captive portal auto-login (filling out forms, accepting terms) | Different problem domain; v1 *avoids* captive networks rather than fighting through them |
| Joining unknown / open networks | Auto-joining networks the user did not explicitly save is a security and trust violation |
| Sharing / syncing WiFi credentials across devices | iCloud Keychain already does this |
| Cellular / hotspot management | Out of domain |
| App Store distribution | Conflicts with the hardened-runtime entitlements `CWInterface.associate(...)` needs; portfolio framing does not require App Store |
| Third-party speed-test services (speedtest.net, fast.com) | Adds external dependency and latency; v1 health probes are self-contained |
| Telemetry / analytics back to the developer | Single-user / portfolio app; no remote collection of user network data |
| BSS-level (single-SSID) roaming (802.11k/v/r) | The WiFi driver already handles intra-SSID BSS roaming; this app explicitly handles cross-SSID switching |
| WiFi heatmaps and spectrum analysis | Different category of tool (WiFi Explorer / NetSpot already exist) |
| Per-application network routing | Out of domain |
| Plugin / extensibility system | YAGNI for v1 |

## Traceability

Which phases cover which requirements. Each v1 REQ-ID maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUND-01 | Phase 1 — Foundations | Pending |
| FOUND-02 | Phase 1 — Foundations | Pending |
| FOUND-03 | Phase 1 — Foundations | Pending |
| FOUND-04 | Phase 1 — Foundations | Pending |
| FOUND-05 | Phase 1 — Foundations | Pending |
| SCAN-01 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| SCAN-02 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| SCAN-03 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| SCAN-04 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| HEAL-01 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| HEAL-02 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| HEAL-04 | Phase 2 — Scanning + Health Probes + BSSID Data Model | Pending |
| HEAL-03 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| DEC-01 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| DEC-02 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| DEC-03 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| DEC-04 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| DEC-05 | Phase 3 — Pure Scoring + Hysteresis Engine | Pending |
| OBS-01 | Phase 4 — Live Decision Loop (Observe-only) | Pending |
| OBS-02 | Phase 4 — Live Decision Loop (Observe-only) | Pending |
| OBS-03 | Phase 4 — Live Decision Loop (Observe-only) | Pending |
| SW-01 | Phase 5 — Active Switching + Manual-Join Respect | Pending |
| SW-02 | Phase 5 — Active Switching + Manual-Join Respect | Pending |
| SW-03 | Phase 5 — Active Switching + Manual-Join Respect | Pending |
| SW-04 | Phase 5 — Active Switching + Manual-Join Respect | Pending |
| SW-05 | Phase 5 — Active Switching + Manual-Join Respect | Pending |
| UI-01 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| UI-02 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| UI-03 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| UI-04 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| UI-05 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| UI-06 | Phase 6 — GUI MVP (MenuBarExtra + Main Window + Settings) | Pending |
| BG-01 | Phase 7 — Background Persistence (Login Item + SwiftData) | Pending |
| BG-02 | Phase 7 — Background Persistence (Login Item + SwiftData) | Pending |
| BG-03 | Phase 7 — Background Persistence (Login Item + SwiftData) | Pending |
| BG-04 | Phase 7 — Background Persistence (Login Item + SwiftData) | Pending |
| BG-05 | Phase 7 — Background Persistence (Login Item + SwiftData) | Pending |
| DIST-01 | Phase 8 — Distribution | Pending |
| DIST-02 | Phase 8 — Distribution | Pending |

**Coverage verification:** 39 / 39 v1 requirements mapped to exactly one phase. No orphans, no duplicates.

---
*Requirements defined: 2026-05-12*
*Last updated: 2026-05-12 after roadmap creation (traceability filled by gsd-roadmapper)*
