# Feature Research

**Domain:** macOS WiFi auto-management / signal-based auto-switching utility
**Researched:** 2026-05-12
**Confidence:** HIGH (multiple verified sources for tool comparisons and roaming standards; MEDIUM for fine-grained UX patterns of closed-source tools where the only signal is marketing copy)

## Landscape Summary

The macOS WiFi tooling space splits into three groups, and `auto-wifi` slots into a near-empty third group:

1. **Passive analyzers** (WiFi Explorer / WiFi Explorer Pro 3, NetSpot, iStumbler, AirRadar, tiny-wifi-analyzer, wandra) — show RSSI, channel, BSSID, SSID, noise, security, vendor; some draw heatmaps. None auto-switch.
2. **Menubar status displays** (WiFi Signal: Strength Analyzer, WiFi Signal Strength Explorer, Wifiry, xbar plugins) — show current SSID/RSSI/tx-rate in the menubar; some warn on degraded quality. None auto-switch.
3. **Auto-switchers** — almost nothing exists. macOS's own `airport prefs joinMode=Strongest` is the closest built-in option; AirRadar markets an auto-connect feature; community tools like `WiFiLocControl` and `LocationChanger` change *network locations* on SSID change but do not pick a better SSID. macOS auto-join itself uses a "score" model (manual connect raises score, manual disconnect lowers it) plus a 12 dB RSSI hysteresis for BSS roaming within the same ESS — but the roam is opaque and doesn't help across distinct SSIDs.

This means `auto-wifi` is differentiated by *existing at all* in category 3, and the bar for "best in class" within that category is low. The realistic competitors are the macOS built-in plus the unofficial `joinMode=Strongest` flag. The portfolio differentiation lives in (a) actually shipping cross-SSID auto-switch with proper hysteresis, (b) using throughput/health, not just RSSI, and (c) a transparent decision log — none of the existing tools surface "why".

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels broken or untrustworthy for a network utility.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Live RSSI of current network** | Every WiFi tool from menubar widgets to NetSpot shows this; users open the app to see it | LOW | `CWInterface.rssiValue()` polled at ~1 Hz |
| **Current SSID + BSSID display** | Basic identification; built-in macOS Option-click menu shows it | LOW | `CWInterface.ssid()`, `.bssid()` |
| **List of known networks currently in range** | Core to the value prop; users need to see what auto-switch is choosing between | LOW | Intersect `CWConfiguration.networkProfiles` with `CWInterface.scanForNetworks()` results |
| **Live signal of each known network in range** | Required to justify any switch decision | LOW | From the scan result set, refreshed periodically |
| **Manual switch trigger** ("Switch now") | Trust requires escape hatches; users need to force a re-evaluation | LOW | Re-run the decision algorithm on demand |
| **Manual override / pause auto-switch** | When on a screenshare / VPN tunnel / large download, users do NOT want a switch mid-stream | LOW | A global enable flag plus optional "pause for N minutes" |
| **Enable/disable auto-switching at all** | First UX a user reaches for; required to debug or compare against macOS default | LOW | Single toggle, persisted |
| **Menubar item with current network + status glyph** | Standard macOS pattern (WiFi Signal, system menu, Bartender ecosystem); MenuBarExtra makes it trivial | LOW | SwiftUI `MenuBarExtra` with `LSUIElement=YES` |
| **Background operation when window closed** | A switcher that only runs when the window is open is useless | MEDIUM | LaunchAgent or background-only LSUIElement app |
| **Connectivity health check on current network** | RSSI alone is insufficient — strong signal to a dead AP is the *exact* failure mode this app exists to fix | MEDIUM | Apple's NWPathMonitor + lightweight ICMP/UDP ping + DNS resolution |
| **Captive-portal-aware non-engagement** | Joining a captive AP and getting stuck is a worse failure than not switching. Out of scope per PROJECT.md but the app must at least *recognize* and avoid them | MEDIUM | Hit `captive.apple.com/hotspot-detect.html` and check expected response; if mismatched, mark network as captive and don't auto-join |
| **Persistent decision history** | Without history, users can't tell whether the app is working or thrashing | LOW | Simple append-only log file in `~/Library/Application Support/auto-wifi/` |
| **Configurable hysteresis thresholds (or at minimum, visible defaults)** | Power users will tune; everyone else needs the numbers visible to trust the algorithm | LOW | `@AppStorage` for thresholds; show current values in settings |
| **Hysteresis on the switch decision itself** | Without it the app is worse than macOS default. Apple itself uses a 12 dB delta on BSS roaming | MEDIUM | Require candidate to beat current by Δ dB AND sustain advantage for T seconds before switching |
| **Graceful Location Services permission flow** | Since macOS 11, SSID/BSSID visibility requires Location authorization; missing this = silent feature failure | MEDIUM | Explicit pre-flight check, in-app explanation, deep link to System Settings if denied |
| **Quit from menubar** | Without a Dock icon there is no other way out of an LSUIElement app | LOW | A Quit item in the MenuBarExtra menu |
| **Launch at login toggle** | Required for any always-running utility; users expect to flip this in app settings | LOW | `SMAppService.mainApp` (macOS 13+) |
| **Dark mode + system appearance respect** | macOS users penalize hard-coded colors; menubar glyphs especially | LOW | SwiftUI's default behavior; just don't fight it |

### Differentiators (Competitive Advantage — Portfolio Impact)

Features that set `auto-wifi` apart from the (very thin) competition. These are where the portfolio story lives.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Throughput-aware scoring, not RSSI-only** | RSSI is documented to correlate poorly with real throughput (Excentis, Mizuno 2023); this is the core thesis of the app and the only reason to exist over `joinMode=Strongest` | HIGH | Combine RSSI, ping latency, ping loss, DNS resolution time, and (optional) brief TCP throughput sample into a composite score. Weighting is the interesting design problem |
| **Transparent decision log — "why did it switch"** | Best-in-class tools (NetworkManager on Linux) only do this via TRACE logs; consumer macOS tools surface nothing. Showing "switched to HomeWiFi: current -82 dBm + 4/10 pings lost; HomeWiFi -54 dBm + 0% loss + 18 ms RTT" is unique | MEDIUM | Each decision is a structured event (timestamp, previous network, candidate network, all metric inputs, threshold evaluated, verdict). Display as a scrollable timeline with filter/search |
| **Sustained-degradation dwell timer + improvement-delta threshold (two-axis hysteresis)** | Consumer Wi-Fi roaming literature (802.11k/v, Cisco, Apple's 12 dB rule) all use single-axis thresholds. A two-axis "must be N dB better AND for T seconds" is more sophisticated and demonstrably prevents flap | MEDIUM | The Cisco CHDM model uses 6 dB hysteresis; Apple uses 12 dB. We add a dwell time so brief spikes don't trigger switches |
| **Per-network policy overrides** | "Never auto-leave OfficeWiFi during work hours"; "Prefer HomeWiFi-5G over HomeWiFi-2.4G regardless of RSSI." Power users will love this | MEDIUM | Per-SSID preferences in settings; merge into composite score |
| **Live scoring panel showing every network's current score and the gap to current** | Makes the algorithm legible at a glance. No competitor does this | LOW | A sortable table in the main window; updates with each scan |
| **Pre-switch dry-run / probe** | Before committing to a switch, do a brief reachability probe against the candidate's BSSID (if same SSID/ESS) or note "I'll only know after I switch" for cross-SSID candidates | MEDIUM | Cross-SSID can't be probed without disassociating; show this caveat in the log |
| **Notification on switch (toggleable)** | A subtle banner "auto-wifi switched to HomeWiFi" gives the user closure without nagging | LOW | UserNotifications framework; default off, opt-in |
| **CSV/JSON export of decision log** | Portfolio storytelling and personal debugging both benefit; turns the app into a small dataset | LOW | One menu item in the main window |
| **Keyboard shortcut for "Pause for 15 min"** | Global hotkey so the user can suppress switching mid-call without clicking the menubar | LOW | Use a hotkey library or `HotKey` Swift package |
| **Snapshot a "WiFi situation"** | One-click capture of "what does the world look like right now" — current network, scan results, scores, recent decisions — to a single file. Excellent for portfolio screenshots and bug reports | LOW | Variant of CSV export plus a screenshot |
| **Composite-score curve graph** | Time-series chart of each known network's composite score over the last hour. Shows why a switch happened — the lines crossed | MEDIUM | SwiftUI `Charts` framework, native on macOS 13+ |
| **Opinionated defaults that just work** | Power users tune; everyone else needs sane defaults. State them explicitly (e.g., "switch if candidate > current by 15 dB OR composite_score by 0.3, sustained 8 s"). Ship with these visible in settings | LOW | Constants in code, exposed read-only in UI for v1 |

### Anti-Features (Commonly Requested, Deliberately Not Built)

Features that seem like obvious additions but create disproportionate problems or violate the project's scope.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Captive portal auto-login** | Coffee shops, hotels — universally annoying. Many users will ask | Different problem domain entirely (HTML parsing, credential storage, ToS acceptance, breakage on every site change). Apple already has Captive Network Assistant for this. Out of scope per PROJECT.md | Detect captive portals so we *avoid* auto-joining them; defer to macOS's CNA for sign-in |
| **Joining unknown / open networks** | "Just connect me to the strongest open WiFi" | Security disaster (rogue APs, MITM, evil-twin); legal exposure; defeats the "known networks" trust model | Document explicitly that the app only operates on user-saved networks |
| **Syncing WiFi profiles or credentials across devices** | "Why doesn't my Mac know my iPhone's saved WiFi?" | iCloud Keychain already does this. Re-implementing is wasted effort and a privacy/security minefield | Document that iCloud Keychain handles this; we read from `CWConfiguration` |
| **Third-party speed test integration (Ookla, fast.com)** | Users trust Ookla numbers | External dependency, rate limits, ToS, network burden, slowness (switch decisions need sub-second metrics). Per PROJECT.md, out of scope | In-app lightweight throughput sample (small TCP transfer to a configurable known host, default Apple's CDN or `1.1.1.1`) |
| **Telemetry / analytics** | "We need to know how users use it" | This is a single-developer portfolio + personal-use app, not a SaaS. Telemetry on a network utility is a trust-killer | Local-only decision log; user can export and share if they want |
| **App Store distribution / paywalls / subscriptions** | "Monetize it" | Out of scope per PROJECT.md; signing+notarizing is sufficient; App Store sandbox would block CoreWLAN/LaunchAgent use anyway | Signed .app, optionally Homebrew Cask, free |
| **Auto-roaming between BSSIDs of the same SSID** | "Why doesn't it pick the closest AP in my mesh?" | macOS's own driver handles 802.11k/v/r BSS roaming, and the 12 dB hysteresis applies *at the BSS level*. Fighting the driver here is a losing battle and likely impossible without kernel hooks | Document that we operate at the SSID layer; recommend same-SSID mesh setups for users who want BSS roaming |
| **Disabling/enabling individual saved networks** | "I want to forget this network temporarily" | macOS Settings already does this; replicating it is scope creep | Link to System Settings → Wi-Fi → Advanced from the main window |
| **Bluetooth / Bonjour / device discovery (à la iStumbler)** | "Add more network features while you're at it" | Wildly out of scope; bloats the app | Stay focused on WiFi auto-switching |
| **Heatmap / site survey (à la NetSpot, AirRadar)** | "I want to see signal across my house" | Different product entirely; requires location tracking, GPS, drawing tools; massive engineering effort | Out of scope; recommend NetSpot if user asks |
| **Full WiFi spectrum analysis (à la WiFi Explorer Pro)** | "Show me channel utilization and non-802.11 interference" | Requires spectrum analyzer hardware integration; off-target for an auto-switcher | Out of scope; recommend WiFi Explorer Pro |
| **Aggressive switching on every metric blip** | "Be more responsive" | This is precisely what the hysteresis exists to prevent. Users who think they want this haven't experienced the consequences | Surface the hysteresis values so users can tune, but don't ship "responsive mode" |
| **Per-app routing / split tunneling** | "Send Zoom over Wi-Fi A and Slack over Wi-Fi B" | Massive complexity (PF firewall rules, kernel extension or NetworkExtension entitlement); separate product | Out of scope |
| **Disabling macOS's own auto-join** | "Auto-wifi should be the sole authority" | We can't reliably suppress macOS's behavior without messing with system preferences. Better to coexist | Document that our switch decisions override macOS's *passive* preference; if conflicts surface, advise the user to lower auto-join priorities of competing networks in System Settings |

## Feature Dependencies

```
[Manual switch trigger]
    └──requires──> [Live scan of known networks in range]
                        └──requires──> [Location Services permission]
                        └──requires──> [CoreWLAN scan capability]

[Auto-switching decision engine]
    └──requires──> [Live scan of known networks in range]
    └──requires──> [Connectivity health check on current network]
    └──requires──> [Hysteresis logic (delta + dwell timer)]
    └──requires──> [Composite scoring function]

[Composite scoring function]
    └──requires──> [RSSI signal]
    └──requires──> [Ping latency + loss]
    └──requires──> [DNS resolution check]
    └──enhances──> [Throughput sample (optional input)]

[Decision log UI]
    └──requires──> [Structured decision events emitted by the engine]
    └──enhances──> [Auto-switching decision engine] (transparency closes the loop)

[Menubar quick controls]
    └──requires──> [LSUIElement=YES app config]
    └──requires──> [SwiftUI MenuBarExtra]
    └──enhances──> [Pause auto-switch]
    └──enhances──> [Manual switch trigger]
    └──enhances──> [Current network display]

[Background operation]
    └──requires──> [LaunchAgent OR LSUIElement-only main process]
    └──requires──> [Auto-switching decision engine running headless]

[Per-network policy overrides]
    └──requires──> [Persistent settings store]
    └──enhances──> [Composite scoring function]
    └──conflicts──with──> [Aggressive "always strongest" mode] (deliberately omitted as anti-feature)

[Notification on switch]
    └──requires──> [UserNotifications permission]
    └──requires──> [Decision events emitted by the engine]

[Captive-portal-aware non-engagement]
    └──requires──> [HTTP probe to captive.apple.com]
    └──enhances──> [Auto-switching decision engine] (excludes captive candidates)

[Composite-score curve graph]
    └──requires──> [Time-series buffer of past scores]
    └──requires──> [SwiftUI Charts framework]
    └──enhances──> [Decision log UI]
```

### Dependency Notes

- **Location Services permission is the gate for everything.** Without it, macOS 11+ returns empty SSID strings on scan results, so the entire app is broken silently. This must be the first onboarding screen and have explicit re-prompts if revoked.
- **Decision log requires structured events from day one.** If decisions emit only `os_log` strings, the log UI becomes a parsing nightmare. Define a `SwitchDecision` struct (timestamp, candidates, metrics, threshold checks, verdict) from the start.
- **Hysteresis logic is upstream of the entire switcher.** Implement the dwell-timer + delta-threshold mechanism before adding throughput-aware scoring; without hysteresis, even a perfect score function will flap.
- **Captive detection must precede candidate evaluation.** If a candidate network is captive, no amount of scoring should pick it. Filter captives out of the candidate pool, don't merely score them low.
- **Background operation + decision engine are tightly coupled.** The engine must run regardless of UI state; the UI is a window into the engine's state, not the engine itself. Architecturally, this means an `ObservableObject` engine owned by the App, not by any specific view.

## MVP Definition

### Launch With (v1)

The smallest set that makes the app demonstrably better than macOS's `joinMode=Strongest` default. Anything less and the portfolio piece reduces to "look, I called CoreWLAN."

- [ ] **Detect saved networks + scan for in-range matches** — without this nothing works
- [ ] **Live RSSI of current network in main window + menubar** — table stakes, basis for everything
- [ ] **Live RSSI of each known network in range** — required for any switch decision to be legible
- [ ] **Connectivity health check on current network (ping + DNS)** — without this we are no better than `joinMode=Strongest`
- [ ] **Hysteresis: delta threshold + dwell timer** — core technical thesis; without this we are *worse* than `joinMode=Strongest`
- [ ] **Composite score (RSSI + health) per network** — the core differentiator; even a simple weighted sum suffices for v1
- [ ] **Automatic switch on a sustained better-score candidate** — the actual feature
- [ ] **Decision log: structured, scrollable, with the metrics that drove each decision** — portfolio story
- [ ] **Enable/disable auto-switch toggle** — trust requires an off switch
- [ ] **Pause for N minutes** — practical necessity for screenshares and large transfers
- [ ] **Menubar item: current SSID, RSSI glyph, quick toggle, quick pause, open main window, quit** — standard macOS UX
- [ ] **Background operation (LSUIElement; LaunchAgent optional in v1, can rely on Login Item)** — without this it doesn't work
- [ ] **Location Services permission onboarding** — without this the app silently fails
- [ ] **Captive portal detection (passive: don't auto-join captive candidates)** — prevents the worst failure mode
- [ ] **Visible hysteresis thresholds in settings (read-only OK for v1)** — transparency
- [ ] **Signed + notarized .app** — required for any non-self distribution and removes Gatekeeper friction even for personal use

### Add After Validation (v1.x)

Features to add once the core engine has been used long enough to expose real edge cases.

- [ ] **Editable hysteresis thresholds in settings** — once defaults have been validated against the developer's own usage
- [ ] **Lightweight throughput sample as an additional score input** — once the cost (in network bytes / battery) has been measured and the value over ping-only is shown
- [ ] **Per-network policy overrides** — once decision-log review reveals specific networks that need different rules
- [ ] **Notification on switch (opt-in)** — once switch decisions are trustworthy enough to celebrate
- [ ] **CSV/JSON export of decision log** — once the log structure is stable
- [ ] **Composite-score curve graph** — once enough decision history exists to make a chart meaningful
- [ ] **Snapshot a WiFi situation** — once portfolio screenshots become a recurring need
- [ ] **Keyboard shortcut for pause** — when the workflow demands it (probably after the first mid-call switch)
- [ ] **Launch-at-login (`SMAppService`) integration** — login-item flow is straightforward but not v1-essential if the developer is the only user
- [ ] **Homebrew Cask formula** — distribute beyond the developer's own machine

### Future Consideration (v2+)

Features that require validation of the core thesis before justifying their cost.

- [ ] **Time-series chart of historical composite scores per network** — needs `Charts` and a real persistence layer
- [ ] **Auto-tuning of hysteresis based on observed flap rate** — machine-learnable, but requires a baseline of decision data
- [ ] **Multi-interface support (Ethernet + WiFi cooperation)** — out of scope per PROJECT.md but adjacent; defer until WiFi-only is rock-solid
- [ ] **iPad Catalyst / iOS support** — explicitly out of scope per PROJECT.md (iOS WiFi APIs too restrictive); reconsider only if Apple opens up the APIs
- [ ] **Plugin system for custom score inputs** — interesting but speculative; only meaningful with users beyond the developer
- [ ] **Sparkle-based auto-update** — only meaningful once there are external users

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Detect saved networks + scan for in-range matches | HIGH | LOW | P1 |
| Live RSSI of current network | HIGH | LOW | P1 |
| Live RSSI of all known nearby networks | HIGH | LOW | P1 |
| Connectivity health check (ping + DNS) on current network | HIGH | MEDIUM | P1 |
| Composite score (RSSI + health) | HIGH | MEDIUM | P1 |
| Hysteresis (delta threshold + dwell timer) | HIGH | MEDIUM | P1 |
| Automatic switch when candidate beats current sustained | HIGH | MEDIUM | P1 |
| Decision log (structured) | HIGH | LOW | P1 |
| Enable/disable auto-switch toggle | HIGH | LOW | P1 |
| Pause for N minutes | HIGH | LOW | P1 |
| Menubar item with current network + quick controls | HIGH | LOW | P1 |
| Background operation (LSUIElement) | HIGH | LOW | P1 |
| Location Services permission flow | HIGH | MEDIUM | P1 |
| Captive portal detection (avoidance, not login) | HIGH | MEDIUM | P1 |
| Visible hysteresis values in settings | MEDIUM | LOW | P1 |
| Signed + notarized build | HIGH | MEDIUM | P1 |
| Editable hysteresis thresholds | MEDIUM | LOW | P2 |
| Lightweight throughput sample input | MEDIUM | MEDIUM | P2 |
| Per-network policy overrides | MEDIUM | MEDIUM | P2 |
| Notification on switch (opt-in) | LOW | LOW | P2 |
| CSV/JSON export of decision log | MEDIUM | LOW | P2 |
| Composite-score curve graph | MEDIUM | MEDIUM | P2 |
| Snapshot a WiFi situation | LOW | LOW | P2 |
| Launch-at-login (SMAppService) | MEDIUM | LOW | P2 |
| Homebrew Cask formula | LOW | LOW | P2 |
| Auto-tuning of hysteresis | LOW | HIGH | P3 |
| Time-series chart with deep history | LOW | MEDIUM | P3 |
| Multi-interface (Ethernet/WiFi cooperation) | LOW | HIGH | P3 |
| Plugin system for custom scoring | LOW | HIGH | P3 |
| Sparkle auto-update | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for v1 launch — the app is incomplete or not differentiated without these
- P2: Add after v1 ships and the core engine has been exercised
- P3: Future consideration; depends on validation of v1

## Competitor Feature Analysis

| Feature | macOS built-in (`joinMode`) | WiFi Signal (Adrian Granados) | WiFi Explorer / Pro 3 | NetSpot | AirRadar | Our Approach |
|---------|----------------------------|-------------------------------|------------------------|---------|----------|--------------|
| Live RSSI of current network | Yes (Option-click menu) | Yes (menubar + main window) | Yes (rich) | Yes (rich) | Yes | Yes — menubar + main window |
| Live RSSI of nearby known networks | Partial (hover Option-click) | No | Yes (all networks, not just known) | Yes (all networks) | Yes | Yes — filtered to known |
| Highlight saved networks | No | No | Filterable | Filterable | Filterable | Yes — known networks are first-class |
| Auto-switch SSID on stronger signal | `joinMode=Strongest` (single-axis, opaque, sometimes ineffective on recent macOS) | No | No | No | Markets it, behavior unclear | **Yes — primary feature with documented algorithm** |
| Auto-switch SSID on health (not just RSSI) | No | No | No | No | No | **Yes — composite score with health input** |
| Two-axis hysteresis (delta + dwell) | 12 dB BSS roam only | N/A | N/A | N/A | N/A | **Yes — explicit, tunable** |
| Decision log / "why did it switch" | No (no UI for it at all) | No | No | No | No | **Yes — first-class structured log** |
| Captive portal handling | Sign-in via CNA | No | No | No | No | Avoidance only (no auto-login) |
| Heatmap / site survey | No | No | No | Yes | Yes | No (deliberate anti-feature) |
| Spectrum analyzer integration | No | No | Pro 3 only | No | No | No (deliberate anti-feature) |
| Menubar SSID + glyph | Yes (system) | Yes | No | No | No | Yes — with quick toggle + pause |
| Pause / disable from menubar | Wi-Fi off only | No | N/A | N/A | N/A | **Yes — pause for N minutes** |
| Background operation | System | Yes | App must be open | App must be open | App must be open | Yes — LSUIElement |
| Open source | N/A | No | No | No | No | **Yes — portfolio piece** |
| Cost | Free (built-in) | Mac App Store paid | Paid (Pro 3 ~$30) | Freemium | Paid | **Free** |

**Reading of the matrix:** The auto-switch column is empty for every consumer tool. Even AirRadar, which advertises auto-connect, doesn't surface the algorithm or expose a decision log. Apple's `joinMode=Strongest` is the only built-in auto-switcher and it's single-axis, opaque, and reportedly weakened in recent macOS versions. The differentiation surface for `auto-wifi` is large and concentrated in: (a) cross-SSID switching with health input, (b) hysteresis sophistication, (c) transparency.

## Open Questions for Downstream Phases

Items the FEATURES research can't resolve without prototype work; flagged for the architecture/research phases that follow.

1. **CoreWLAN association reliability.** Open-source `macos-wifi` notes "doesn't seem to work reliably" for BSSID association. Need to validate that `CWInterface.associate(to:password:)` reliably switches networks on macOS 14+ without requiring `sudo`. If not, the app might be limited to *recommending* switches rather than executing them.
2. **Background-process Location Services prompt.** Will an LSUIElement / LaunchAgent process trigger the Location Services dialog the same way a foreground app does, or will it silently fail until the user opens the main window once? Affects onboarding flow.
3. **Throughput sampling without disrupting user traffic.** What's the smallest payload that yields a usable throughput estimate? RFC 6349 recommends multi-second TCP transfers, which are too heavy. Likely answer: don't ship throughput sampling in v1; rely on ping/DNS, and add throughput later if needed.
4. **Captive-portal probe latency.** `captive.apple.com` round-trip costs time on every scan; we may need to cache per-BSSID captive verdicts.
5. **Default threshold values.** What delta (dB) and dwell (seconds) produce zero observed flap in a typical home setup? Must be calibrated empirically; ship reasonable starting guesses (~10 dB delta, ~8 s dwell) and refine.

## Sources

Tool comparisons and capabilities:
- [Top 8 Best WiFi Analyzer Apps for Your Mac in 2026 — NetSpot](https://www.netspotapp.com/wifi-analyzer/best-wifi-analyzer-mac.html)
- [Best WiFi Analyzer Apps for Your Mac (macOS Sequoia Ready) — insanelymac](https://www.insanelymac.com/blog/best-wifi-analyzer-for-mac/)
- [Free and low-cost Wi-Fi stumblers for the Mac — Network World](https://www.networkworld.com/article/2960517/review-free-and-low-cost-wi-fi-stumblers-for-the-mac.html)
- [WiFi Explorer Pro 3 — Intuitibits](https://www.intuitibits.com/products/wifiexplorerpro3/)
- [WiFi Signal: Strength Analyzer — Mac App Store](https://apps.apple.com/us/app/wifi-signal-strength-analyzer/id525912054?mt=12)
- [GitHub — chbrown/macos-wifi (CoreWLAN CLI, notes on association reliability)](https://github.com/chbrown/macos-wifi)
- [GitHub — nolze/tiny-wifi-analyzer](https://github.com/nolze/tiny-wifi-analyzer)
- [GitHub — mikaellofgren/wandra](https://github.com/mikaellofgren/wandra)
- [WiFiLocControl — DEV Community](https://dev.to/vborodulin/wifiloccontrol-macos-network-location-switcher-based-on-the-wi-fi-name-4cb4)
- [GitHub — rimar/wifi-location-changer](https://github.com/rimar/wifi-location-changer)

macOS built-in behavior and `airport prefs`:
- [How iOS, iPadOS, and macOS decide which wireless network to auto-join — Apple](https://support.apple.com/en-us/102169)
- [macOS wireless roaming for enterprise customers — Apple](https://support.apple.com/en-us/HT206207)
- [Wi-Fi network roaming with 802.11k, 802.11r, and 802.11v on Apple — Apple](https://support.apple.com/en-us/103274)
- [Make MacOS roam to the strongest wifi signal — Back in 5 mins (joinMode docs)](https://jay.gooby.org/2021/01/14/make-os-x-roam-to-the-strongest-wifi-signal)
- [macOS Wi-Fi Roaming — Frame by Frame WiFi](https://framebyframewifi.net/2017/08/20/macos-wi-fi-roaming/)
- [Switch to a WiFi with strong signal automatically — Apple Community](https://discussions.apple.com/thread/254898123)

Roaming standards (hysteresis, 802.11k/v/r):
- [802.11r, 802.11k, 802.11v: The Three Protocols That Make WiFi Roaming Seamless — Referently](https://referently.com/802.11r-802.11k-802.11v-the-three-protocols-that-make-wifi-roaming-seamless/)
- [Wi-Fi 7 Roaming Security: 802.11r/k/v Essentials — PulseGeek](https://pulsegeek.com/articles/wi-fi-7-roaming-security-802-11r-k-v-essentials/)
- [Understand 802.11r/11k/11v Fast Roams on 9800 WLCs — Cisco](https://www.cisco.com/c/en/us/support/docs/wireless/catalyst-9800-series-wireless-controllers/221671-understand-802-11r-11k-11v-fast-roams-on.html)
- [Cisco Wireless Controller Configuration Guide — Client Roaming (CHDM hysteresis)](https://www.cisco.com/c/en/us/td/docs/wireless/controller/8-10/config-guide/b_cg810/client_roaming.html)

RSSI vs. throughput literature:
- [WiFi Performance Metrics for Optimal Connectivity — NetBeez](https://netbeez.net/blog/wifi-performance-metrics/)
- [Wi-Fi signal strength: are your investments based on shaky data — Excentis](https://www.excentis.com/blog/blog-6/wi-fi-signal-strength-are-your-investments-in-wireless-infrastructure-based-on-shaky-data-39)
- [Interpreting RF Benchmark Results: From RSSI to Throughput — PatSnap Eureka](https://eureka.patsnap.com/article/interpreting-rf-benchmark-results-from-rssi-to-throughput)
- [A simple metric that correlates with public Wi-Fi throughput (Mizuno 2023) — IET Electronics Letters](https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/ell2.12795)
- [RFC 6349 — Framework for TCP Throughput Testing](https://datatracker.ietf.org/doc/html/rfc6349)

Captive portal handling on macOS:
- [What is captive.apple.com/hotspot-detect — Apple Community](https://discussions.apple.com/thread/7491051)
- [Captive portal detection — Apple Developer Forums](https://developer.apple.com/forums/thread/747798)
- [HTTPS Captive Network wifi disconnect — Apple Developer Forums](https://developer.apple.com/forums/thread/86589)

Connectivity health checks (ping/DNS in Swift):
- [Introducing LCLPing: lightweight ping library — Swift Forums](https://forums.swift.org/t/introducing-lclping-a-lightweight-ping-library-for-latency-and-reachability-measurement/72694)
- [Measure pings to any host using Network framework — Vitaliy Podolskiy (Medium)](https://medium.com/@onlyapps/measure-pings-to-any-host-using-network-framework-ios-swift-3092ef367cd6)
- [GitHub — rldaulton/connectedness](https://github.com/rldaulton/connectedness)

Menubar / SwiftUI patterns (macOS Sonoma+):
- [MenuBarExtra — Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Create a mac menu bar app in SwiftUI with MenuBarExtra — Sarunw](https://sarunw.com/posts/swiftui-menu-bar-app/)
- [Build a macOS menu bar utility in SwiftUI — Nil Coalescing](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)
- [Showing Settings from macOS Menu Bar Items — Peter Steinberger](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- [SwiftUI Menu Bar App With a Floating Window — Fazm](https://fazm.ai/blog/swiftui-menu-bar-app-floating-window-best-practices)

CoreWLAN reference:
- [Core WLAN — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan)

Code signing / notarization / distribution:
- [Notarizing macOS software before distribution — Apple Developer](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [App code signing process in macOS — Apple Support](https://support.apple.com/guide/security/app-code-signing-process-sec3ad8e6e53/web)
- [macOS distribution: code signing, notarization, quarantine — rsms gist](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5)

---
*Feature research for: macOS WiFi auto-switching utility*
*Researched: 2026-05-12*
