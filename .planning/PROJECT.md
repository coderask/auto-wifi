# auto-wifi

## What This Is

A macOS GUI app that intelligently manages connections to known WiFi networks. Continuously measures signal strength and real throughput across nearby known networks, and switches to the best-performing one — with hysteresis to prevent flapping between networks of similar quality. Built for personal use and as a portfolio piece.

## Core Value

When multiple known WiFi networks are in range, the user is always on the genuinely best one — and never stranded on a dead or weak network because macOS was slow to switch.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Detect all nearby WiFi networks the user has saved (known networks)
- [ ] Continuously measure signal strength (RSSI) of each nearby known network
- [ ] Continuously measure actual throughput / health of the currently-connected network (not just RSSI — ping latency, DNS reachability, optional speed sample)
- [ ] Switch to a better known network when the current one is degraded, with hysteresis so the app does not oscillate between networks of similar quality
- [ ] User-visible main window showing: current network, nearby known networks, live signal/health metrics, and switch decisions/history
- [ ] Menubar item showing current network and quick status indicator
- [ ] User can enable/disable auto-switching from the GUI
- [ ] User can tune hysteresis thresholds and switch sensitivity from the GUI (or at minimum, see the values being used)
- [ ] Decisions log: the app explains *why* it switched (e.g., "switched to HomeWiFi — current network RSSI -82 dBm + 4 failed pings; HomeWiFi RSSI -54 dBm and reachable")
- [ ] Runs as a background agent (LaunchAgent) so it works even when the GUI window is closed

### Out of Scope

- iOS / iPadOS / Windows / Linux support — macOS-only for v1 (iOS WiFi APIs are heavily restricted, and the user's frustration is macOS-specific)
- Captive portal auto-login — different problem domain; v1 should *avoid* captive networks rather than fight through them
- Sharing/syncing WiFi credentials across devices — covered by iCloud Keychain already
- Joining unknown / open networks — v1 only works with networks already saved to the system
- Cellular / Hotspot management
- App Store distribution / payments — portfolio + personal use, distributed as a signed .app or via Homebrew Cask
- Speed-test third-party services (speedtest.net etc.) — implement lightweight throughput sampling locally instead

## Context

- **Owner:** Aarnav Koushik (single developer, personal use + portfolio).
- **Frustration that prompted this:** macOS sticks with the wrong WiFi network — it stays on weak/dead networks instead of switching to a stronger known one nearby, and is slow to fall back. This is a recurring annoyance in environments with overlapping networks (home with multiple APs, office, coffee shops with multiple known SSIDs in range).
- **Why hysteresis matters:** A naive "switch to highest RSSI" implementation flaps endlessly between two near-equal networks. Hysteresis (require *meaningful* improvement before switching, and require *sustained* degradation before abandoning the current one) is the core technical interest of the project.
- **Portfolio framing:** The app should look and feel polished — clean SwiftUI interface, observable internal state, well-explained decisions. The decision log is both a debugging tool and a showcase of the thinking behind the algorithm.
- **Built-in macOS behavior to beat:** macOS auto-join is opaque, slow, prefers the most-recently-joined network rather than the best one, and has no user-visible signal/health metrics. This app should be transparent where macOS is opaque.

## Constraints

- **Tech stack**: Swift + SwiftUI for the GUI — Why: native macOS look, portfolio-worthy modern stack, full access to system frameworks.
- **WiFi APIs**: CoreWLAN (CWInterface, CWWiFiClient) for scanning and association — Why: only sanctioned macOS API for this, and `networksetup` is too coarse for live RSSI/scan results.
- **Network health**: Apple's Network framework + lightweight in-app probes (ping, DNS lookup) — Why: avoids third-party speed-test dependencies and keeps the app self-contained.
- **Privileges**: CoreWLAN requires either Location Services permission (modern macOS) or an admin entitlement for some actions — Why: macOS gates SSID/BSSID visibility behind Location authorization since macOS 11.
- **Distribution**: Signed/notarized .app, optionally Homebrew Cask — Why: portfolio piece, not App Store, so signing+notarization is enough.
- **Platform**: macOS only, target macOS 14+ (Sonoma) — Why: modern SwiftUI features and current CoreWLAN behavior; no need to support legacy.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| macOS-only, no cross-platform | Frustration is macOS-specific; iOS WiFi APIs are too restricted; cross-platform adds enormous complexity for no portfolio gain. | — Pending |
| Native Swift + SwiftUI, not Electron/Tauri | Portfolio impact + native system access (CoreWLAN, LaunchAgent). | — Pending |
| Signal + measured throughput, not signal alone | RSSI alone is unreliable — a strong signal to a broken AP is worthless. Health checks (ping/DNS) catch this. | — Pending |
| Hysteresis from day one | The whole point. Without it, the app would be worse than macOS default. | — Pending |
| Decision log as a first-class feature | Doubles as portfolio storytelling and as the developer's own debugging surface. | — Pending |
| Known networks only in v1 | Captive portals and unknown networks are separate problem domains. | — Pending |
| LaunchAgent for background operation | App needs to work continuously, not only when the GUI is open. | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-05-12 after initialization*
