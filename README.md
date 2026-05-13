# auto-wifi

> A macOS app that intelligently auto-switches between your known Wi-Fi networks — and explains every decision it makes.

macOS's built-in Wi-Fi auto-join is opaque, slow, and prefers the most-recently-joined network over the genuinely best one. **auto-wifi** continuously measures signal strength *and* real connection health across every known network in range, and switches to the best-performing one — with multi-layer hysteresis to prevent the flapping that a naive "highest RSSI wins" implementation would cause. Every decision (and every *rejected* would-be switch) is logged with a plain-language reason.

```
Engine state: STEADY                                    OBSERVE
Last decision: STAY · current 'HomeWiFi-5G' at -54 dBm is above good-enough threshold (-67 dBm); not considering switch
```

---

## Status

This is a personal/portfolio build. **Default mode is "Observe"** — the engine runs continuously and logs decisions but does not actually switch networks until you explicitly flip the toggle to "On".

- v0.1 — phases 1-7 complete (foundations, scanning, health probes, hysteresis algorithm, observe loop, switching, GUI, persistence)
- v0.2 — phase 8 (signed/notarized DMG distribution) pending an Apple Developer Program membership

---

## What it does

**Composite scoring.** Every nearby known Wi-Fi network gets a composite score combining:

| Input | Source | Notes |
| --- | --- | --- |
| RSSI (signal strength) | CoreWLAN scan | Smoothed via exponential moving average (α=0.3) so a single noisy sample can't flip the decision |
| Latency + DNS health | Network framework probes | Only sampled for the *currently-connected* network — nearby APs don't reveal their backhaul quality |
| Captive-portal flag | `captive.apple.com` after association | Probed once per `(SSID, BSSID)` and remembered; large negative score modifier |
| Band preference | Channel data | Small bonus for 5 GHz and 6 GHz |
| User preference | You, in Settings → Networks | Prefer / Neutral / Avoid / Never-auto-join |

**Multi-layer hysteresis.** Five independent gates prevent flapping:

1. **EMA smoothing** of RSSI samples — a single bad reading doesn't trigger anything.
2. **Threshold bands** — current connection above −67 dBm is "good enough" and no switch is even considered, even if a competitor looks marginally better. Below −75 dBm starts the degrade timer.
3. **Degrade dwell timer** — the current connection must stay weak for 10 continuous seconds before alternatives are evaluated.
4. **Candidate dwell timer** — a candidate must look meaningfully better for 8 continuous seconds before we commit.
5. **Post-switch cooldown** — 30 seconds frozen after a switch so the new connection can settle.

Plus a 2× margin multiplier when active traffic is detected (large transfers, Zoom calls), so the engine won't kick you mid-meeting for a marginal improvement.

**Transparent decision log.** Every evaluation cycle produces a structured `Decision` event including switches considered and rejected — and *why* they were rejected:

```
SWITCH  switching: 'Cafe-5G' (+18.7) sustained +21.3-point advantage over 'HomeWiFi' (-2.6) for 8s
REJECT  candidate 'Cafe-5G' only +6.0 points better than current (need +15.0); short by +9.0
COOLDOWN  post-switch cooldown: 23s remaining
GOOD    current 'HomeWiFi-5G' at -54.3 is above good-enough threshold (-67 dBm); not considering switch
```

---

## Installing (for tech-savvy testers)

> ⚠ This build is **ad-hoc signed** — macOS Gatekeeper will show a warning on first launch and the system Location prompt will not appear automatically. The notarized v0.2 release will fix both issues. Until then:

### One-time setup

1. **Download.** Get `auto-wifi.dmg` (or `auto-wifi.zip` if that's what you were sent).
2. **Install.**
   - **From the DMG** (recommended): double-click → drag `auto-wifi.app` onto the Applications shortcut → eject the disk image.
   - **From the zip**: double-click to extract → drag `auto-wifi.app` into `/Applications/` yourself.

   Moving to `/Applications/` is required either way — macOS will not grant Location Services authorization to apps run from arbitrary directories.
3. **First launch.** Right-click `auto-wifi` in `/Applications/` → **Open** → confirm the Gatekeeper warning (it appears because the build isn't notarized yet; future v0.2+ will skip this step).
4. **Open the main window.** It'll appear automatically on first launch; click **Continue**.
5. **Grant Location.** The system prompt may not appear (TCC silently suppresses prompts for ad-hoc-signed apps). If you don't see one:
   - Open **System Settings → Privacy & Security → Location Services**
   - Find **auto-wifi** in the list, toggle it **on**
   - This is *required* — macOS hides Wi-Fi network names (SSIDs and BSSIDs) from any app that doesn't have Location auth. The inspector will look empty until you grant.
6. **Done.** The app lives in your menubar from now on (look for a wifi icon next to your network name at the top-right of your screen). The main window can be closed; the app keeps running.

> **Why does it need Location?** macOS treats nearby Wi-Fi network names as location data — public BSSID-to-coordinates databases mean a list of nearby APs reveals where you are with meter-level accuracy. Apple gates that data behind Location Services. auto-wifi never logs, stores, or transmits your geographic location — the permission only unlocks Wi-Fi metadata. [More on this](https://developer.apple.com/forums/thread/748518).

### Using it

- **Menubar icon** shows your current SSID and a status glyph: 📶 steady, ⚠️ degraded, 🔄 switching, ⏳ cooldown.
- Click the icon for the panel: **Auto-switch** toggle (Off / Observe / On — defaults to Observe), **Pause for N minutes** buttons, "Open main window," "Settings…", "Quit."
- **Default mode is Observe.** The engine runs and logs decisions, but never actually switches networks. Run for a few days, look at the decision log, then flip to "On" when you trust it.
- The **main window** shows your current connection, live health metrics, the scoring table for nearby known networks, and the live decision log with filters (All / Switches / Rejected / Errors).
- **Settings → Algorithm** shows the read-only hysteresis thresholds. **Settings → Networks** lets you tag a specific SSID as Prefer / Avoid / Never-auto-join. **Settings → Background** lets you enable login-item registration so it starts automatically.

### Validating that it works

After running in **Observe** mode for a day or two of normal use, inspect the decision log:

```sh
tail -50 ~/Library/Application\ Support/auto-wifi/decisions.jsonl | python3 -m json.tool --json-lines
```

| Signal | Means |
| --- | --- |
| Mostly `stayCurrentGoodEnough` while on a strong network | Algorithm isn't being trigger-happy ✓ |
| `rejectedSwitch` near network edges with multiple known APs visible | Hysteresis is doing its job ✓ |
| FSM transitions `steady → degraded → steady` as signal fluctuates | State machine is tracking reality ✓ |
| `switchTo` entries clustering when you actually moved | Algorithm is detecting real changes ✓ |
| `switchTo` entries when nothing changed for you | Calibration is off — let me know |
| Same two networks ping-ponging in the log | Hysteresis is broken — definitely let me know |

### Uninstalling

```sh
# Quit from the menubar first, then:
rm -rf /Applications/auto-wifi.app
rm -rf ~/Library/Application\ Support/auto-wifi
# Settings → Privacy & Security → Location Services → toggle auto-wifi off (or just delete the entry)
# Settings → General → Login Items → remove auto-wifi if you enabled it
```

---

## Sharing data back

If you've run for a few days and want to send your decision log back for analysis:

```sh
# A copy of every Decision the engine made, 90 days max
cp ~/Library/Application\ Support/auto-wifi/decisions.jsonl ~/Desktop/auto-wifi-decisions.jsonl
```

The JSONL contains: timestamps, action kinds (`stay` / `switchTo` / `rejectedSwitch` / etc.), human-readable reasons, the current/target SSID + BSSID, and the FSM state after each decision. **No location data, no traffic content, no passwords.** SSIDs and BSSIDs are technically identifiers but everything else lives in your own JSONL file on your own machine.

---

## Building from source

Requires macOS 14+ and Swift 6.0+ (ships with the Xcode Command Line Tools).

```sh
git clone <repo-url> auto-wifi
cd auto-wifi
make app                                # builds dist/auto-wifi.app
make test                               # runs the 17 algorithm tests
open dist/auto-wifi.app                 # or copy to /Applications first
```

### Build pipeline

| Target | What it does |
| --- | --- |
| `make build` | `swift build` only |
| `make test` | runs `AlgorithmsRunner` (17 synthetic-input tests) |
| `make app` | builds + assembles a launchable `.app` in `dist/` (ad-hoc signed, hardened runtime) |
| `make run` | `make app` + opens the app |
| `make distribute` | builds + zips into `dist/auto-wifi.zip` for sharing |
| `make sign` | re-signs with Developer ID (requires `DEVELOPER_ID_APPLICATION` env var) |
| `make notarize` | submits to Apple notarization service + staples (requires `notarytool` keychain profile) |
| `make dmg` | wraps the signed/notarized app into a DMG |
| `make release` | full pipeline: build → sign → notarize → DMG |

---

## Architecture

```
            ┌──────────────────────────────────────────────────┐
            │                   AppState                       │
            │      @MainActor @Observable, owns everything     │
            └──────────────────────────────────────────────────┘
                              │
       ┌──────────────┬───────┴──────┬─────────────┬───────────┬───────────────┐
       ▼              ▼              ▼             ▼           ▼               ▼
  ScanCoordinator  HealthProbe   CaptiveProbe   GuardState  TrafficWatcher  DecisionLoop ──▶ SwitchActor
   (CoreWLAN +      (Network       (URL probe    (pause +    (getifaddrs    (pure engine +    (CWInterface
   adaptive         framework      to Apple)     manual       byte rates)    + persistence       associate)
   cadence)         + ping/DNS)                  hold)                       sink)
                                                                                  │
                                                                                  ▼
                                                                          PersistenceActor
                                                                          (JSONL on disk)
                                                                                  │
                                                                                  ▼
                                                                            Algorithms
                                                                          (pure-Swift,
                                                                           zero framework
                                                                            imports)
```

The `Algorithms` module is **framework-free** — no CoreWLAN, no Network framework, no AppKit, no SwiftUI imports. The hysteresis math is `(state, inputs) -> (state', decision)` and is exercised entirely with synthetic inputs in `swift run AlgorithmsRunner`.

Built with: Swift 6.2, SwiftUI, CoreWLAN, CoreLocation, Network, ServiceManagement, OSLog. Targets macOS 14+ (Sonoma). No third-party dependencies.

---

## Roadmap

- ✅ **Phase 1** — Signed `.app` shell with Location Services authorization and CoreWLAN read of known networks
- ✅ **Phase 2** — Continuous scanning + ping/DNS health probes + captive portal detection + BSSID-keyed data model
- ✅ **Phase 3** — Pure scoring + multi-layer hysteresis engine (17 synthetic-input tests)
- ✅ **Phase 4** — Observe-only decision loop with filterable in-app log
- ✅ **Phase 5** — Active switching + manual-join respect + active-traffic awareness + pause controls
- ✅ **Phase 6** — `MenuBarExtra` + Settings scene with per-network preferences (`LSUIElement`)
- ✅ **Phase 7** — `SMAppService.loginItem` background registration + JSON persistence + 90-day decision-log rollover
- ⏳ **Phase 8** — Developer ID signing + notarization + DMG (pending $99/year Apple Developer Program enrollment)

v2 ideas: editable hysteresis thresholds in the UI, throughput sampling beyond ping/DNS, opt-in switch notifications, Sparkle auto-update, Homebrew Cask distribution, SwiftUI Charts visualization of score-over-time.

---

## Acknowledgments

Algorithm design draws on standard Wi-Fi roaming literature (Cisco/Juniper/Meraki engineering docs on RSSI hysteresis and sticky-client mitigation) and the actor-per-concern macOS architecture pattern. macOS Location Services / CoreWLAN integration follows the conventions laid out in Apple Developer Forums threads on Sonoma 14.4+ SSID redaction behavior.

---

© 2026 Aarnav Koushik
