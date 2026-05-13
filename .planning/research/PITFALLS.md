# Pitfalls Research

**Domain:** macOS GUI app that scans, scores, and auto-switches between known WiFi networks (CoreWLAN + SwiftUI)
**Researched:** 2026-05-12
**Confidence:** HIGH on macOS permission/notarization issues (Apple docs + multiple developer forum reports). HIGH on roaming/hysteresis algorithm pitfalls (Cisco/Juniper/Meraki + WiFi engineering literature). MEDIUM on exact CoreWLAN behavior on macOS 14.4+ since the API surface has been actively changing.

---

## Critical Pitfalls

### Pitfall 1: SSID/BSSID returns nil because Location Services is not authorized

**What goes wrong:**
`CWInterface.ssid()`, `CWInterface.bssid()`, and `CWNetwork.ssid` return `nil` (or empty/redacted strings like `"<redacted>"`). Network scanning still appears to "work" — you get `CWNetwork` results — but every identifying field is missing, so the app cannot tell which network is which. New developers commonly conclude "CoreWLAN is broken" and waste days.

**Why it happens:**
Starting in macOS 10.15 and tightened again in macOS 14.4 (Sonoma), Apple gates SSID/BSSID visibility behind Location Services authorization. The framework no longer fails loudly — it just returns nil. The reason is that the BSSID list functions as a coarse geolocation signal, so Apple now treats it as location data.

**How to avoid:**
- Add `NSLocationUsageDescription` (and `NSLocationWhenInUseUsageDescription` on more recent SDKs) to `Info.plist` with a clear user-facing string explaining *why* WiFi inspection needs location.
- Use `CLLocationManager` to request authorization explicitly, do not assume the OS will prompt from CoreWLAN side-effects (it will not).
- "When in Use" is sufficient for a foreground GUI app; "Always" is required if you intend to scan from a LaunchAgent context with no foreground window. For this project, "Always" is the correct ask because the LaunchAgent must continue scanning when the GUI is closed.
- Build as a proper `.app` bundle (LSUIElement is fine). **Command-line tools cannot get SSID/BSSID even with location granted** — they have no Info.plist identity to request authorization against. Do all CoreWLAN access from the app bundle, not from a CLI helper.
- On first run, if `ssid()` returns nil, the app should detect this and present a remediation UI ("Open System Settings > Privacy & Security > Location Services") rather than silently failing.

**Warning signs:**
- `CWNetwork.ssid` is `nil` even though `interfaceMode` reports `.station` and Wi-Fi obviously works.
- `scanForNetworks(withName:)` returns a non-empty set but every entry has nil SSID.
- Works in debug from Xcode (parent process has location) but breaks when launched from Finder.

**Phase to address:** Phase 1 (foundations / CoreWLAN spike). This must be solved before any algorithm work, because without identifying networks, nothing else functions.

---

### Pitfall 2: Over-scanning kills the battery and degrades Wi-Fi for the whole system

**What goes wrong:**
Tight scan loops (every 2-5 seconds) cause severe battery drain, heat, and — counterintuitively — *worse* connectivity. Active scans force the radio to leave its home channel to probe other channels, which interrupts the user's actual traffic (visible as packet loss spikes, video call freezes, and inflated ping latency on the current connection).

**Why it happens:**
A CoreWLAN scan is not a passive read. It puts the radio into scan mode across all channels (2.4 GHz: 11-14 channels, 5 GHz: dozens of channels including DFS scans which take seconds each). Each scan is a hundreds-of-milliseconds to multi-second blocking operation that interrupts data. New developers see "scan returns instantly with cached data sometimes" and assume scans are cheap — but the underlying cost is borne when the OS decides the cache is stale.

**How to avoid:**
- Set a default scan cadence of **30-60 seconds** when the user is connected and connection is healthy. Drop to **10-15 seconds** only when the current connection appears degraded (failing pings, RSSI below threshold, throughput drop).
- Make scan cadence adaptive: stable healthy state → slow scans; degraded state → fast scans; on battery vs on power → multiply cadence by 2x on battery.
- Never scan in a tight `while true { sleep(1); scan() }` loop. Use a `DispatchSourceTimer` or `Timer` you can adjust.
- Use `scanForNetworks(withName:)` with `nil` (full scan) sparingly. When you only care about a specific known SSID for re-check, pass that name to scope the scan.
- Cache scan results with a TTL (~15 seconds) so multiple subsystems (scoring, UI, health check) share one scan rather than each triggering their own.

**Warning signs:**
- Activity Monitor reports the app under "Significant Energy Use."
- User complains video calls stutter every N seconds while the app is running (N = scan period).
- `powermetrics --samplers wifi` shows continuous high airtime usage by your process.
- Mac fans spin up when the app is in the foreground.

**Phase to address:** Phase 2 (scanning engine). Build adaptive scan scheduling from day one — it is much harder to retrofit later because the rest of the system gets wired to assume fast scans.

---

### Pitfall 3: Naive "highest RSSI wins" causes network flapping (the very problem this app exists to solve)

**What goes wrong:**
The app oscillates between two nearby networks every few seconds. Each switch costs the user 3-10 seconds of disconnection (DHCP, ARP, captive check, TLS re-handshake on every open connection). Users describe this as "worse than just doing nothing" and turn the app off.

**Why it happens:**
RSSI is noisy. At any given instant, two networks of "equal" quality might report -65 dBm and -67 dBm; one second later, -66 and -64. A pure max-RSSI selector will flip on every measurement. This is the classic anti-pattern that even commercial WiFi controllers got wrong for years (Cisco's "Optimized Roaming" exists precisely to solve it).

**How to avoid:**
- **Asymmetric hysteresis:** Require the candidate network to be meaningfully *better* than the current one before switching, not just better. Industry guidance from Cisco/Juniper recommends a 3-6 dB RSSI improvement margin minimum, with 6 dB being more conservative.
- **Time hysteresis (dwell):** Require the candidate to be better for N consecutive samples (e.g., 3 samples over 30 seconds) before triggering a switch. A single sample is never enough.
- **Minimum dwell time on current network:** Refuse to consider switching for the first 60 seconds after any switch. This bounds the maximum switch rate to once per minute even in pathological conditions.
- **Smoothing before comparison:** Apply EWMA (alpha ~0.3) or a windowed median (3-5 samples) to each network's RSSI before comparing. Compare smoothed values, not raw samples.
- **Compound score, not raw RSSI:** Score = f(smoothed RSSI, recent health probes, band preference). A network with -75 dBm and working DNS beats a network with -55 dBm and failing pings.

**Warning signs:**
- Decision log shows more than 1 switch per minute under stable physical conditions.
- "Switch reason" log entries cite RSSI deltas under 3 dB.
- User reports VPN reconnecting frequently.
- Switch history shows A→B→A→B alternation.

**Phase to address:** Phase 3 (scoring + switching algorithm). The hysteresis logic IS the product — it must be designed before any switching code is written, not bolted on after observing flapping.

---

### Pitfall 4: Joining a captive portal network because it "scores well" on RSSI

**What goes wrong:**
The app sees a strong-signal known network (e.g., "AttWifi" or a hotel network the user saved months ago), switches to it, and the user is now behind a captive portal login page. Existing TCP connections die. The Captive Network Assistant pops up. The user loses 30-60 seconds and trust in the app.

**Why it happens:**
RSSI says nothing about whether a network requires authentication. The macOS Captive Network Assistant runs *after* association. There is no native macOS API to ask "is this network captive?" before joining — `CNCopySupportedInterfaces` exists but returns `null` on macOS, and macOS does not expose its own captive determination programmatically.

**How to avoid:**
- **Captive flag per saved network**, manually settable by the user (a checkbox: "This network requires login"). Defaults to "unknown" and is learned over time.
- **Auto-detection after first join:** Probe `http://captive.apple.com/hotspot-detect.html` after every association. If it does not return the literal string "Success" within ~3 seconds, mark this BSSID/SSID as captive in the app's local store.
- **Score penalty for captive networks:** Default behavior should be to *avoid* networks marked captive (apply a large negative score modifier, effectively excluding them unless they are the only option).
- **Never switch automatically TO a captive network** unless the current connection is fully unusable and the user has explicitly opted in to captive fallback per network.
- For users who want it, allow a per-SSID setting "auto-join even though captive" — but make it explicit.

**Warning signs:**
- After an auto-switch, the user sees the Captive Network Assistant window pop up.
- Health probes (ping to 1.1.1.1, DNS lookup) consistently fail right after a switch to a particular SSID.
- The app's HTTP probe to `captive.apple.com` returns HTML that doesn't contain "Success".

**Phase to address:** Phase 3 (scoring) for the per-network flag in the data model, Phase 4 (health checks) for the active captive probe and the score penalty. Out of scope for v1 per PROJECT.md is *fighting through* the captive portal — the app's job is to *avoid* it, not log in.

---

### Pitfall 5: Same SSID on 2.4 GHz and 5 GHz treated as one network

**What goes wrong:**
The user has a router that broadcasts "HomeWiFi" on both 2.4 GHz and 5 GHz (extremely common). The app sees two `CWNetwork` entries with the same SSID. It either:
(a) deduplicates them by SSID and arbitrarily picks one BSSID's metrics, losing the ability to prefer 5 GHz; or
(b) treats them as wholly separate "networks" that the user has to configure twice in the UI.

Both are wrong. The user thinks of it as one network but the app needs to track two radios.

**Why it happens:**
SSID is not unique — BSSID (the MAC of the specific radio) is. CoreWLAN returns one `CWNetwork` per visible BSSID. Developers either forget this and key everything by SSID, or overcorrect and surface BSSIDs in the UI (which users do not understand).

**How to avoid:**
- **Internally key by BSSID**, externally display by SSID. Keep a `(SSID, BSSID, band, channel)` tuple as the canonical identity of a candidate.
- **Aggregate to "best BSSID per SSID"** when presenting to the user: show one row per SSID with the metrics of whichever band/AP is currently best.
- **Band preference as a tiebreaker, not a hard rule:** prefer 5 GHz when RSSI delta is small (e.g., 5 GHz wins if it is within 5-8 dB of 2.4 GHz), but 2.4 GHz wins clearly if it has much better signal. 5 GHz attenuates faster, so a slightly weaker 5 GHz reading is often actually worse than 2.4 GHz.
- **Track band per BSSID** so the scoring function can factor it in.

**Warning signs:**
- UI shows the same SSID twice in the "nearby networks" list.
- App prefers a -70 dBm 5 GHz AP over a -55 dBm 2.4 GHz AP on the same router.
- Decision log doesn't mention band/frequency in switch reasons.

**Phase to address:** Phase 2 (data model — BSSID-keyed) and Phase 3 (scoring — band as tiebreaker).

---

### Pitfall 6: LaunchAgent and "Background Items Added" notification surprises (Ventura/Sonoma)

**What goes wrong:**
The user installs the app and immediately sees a "Background item added" notification from macOS. Possibly worse: every time the LaunchAgent is updated or re-registered, the notification fires again. The user gets suspicious ("what is this background thing watching my Wi-Fi?") and disables the agent in System Settings > General > Login Items, breaking the app.

**Why it happens:**
Since macOS Ventura (13), macOS shows a notification any time a new background item is registered via `SMAppService`, `SMLoginItemSetEnabled`, or a `LaunchAgents`/`LaunchDaemons` plist. Older `~/Library/LaunchAgents` installations also trigger this and additionally have no good install/uninstall story. There were also notable bugs in early Ventura where the notification fired *every* login regardless of changes.

**How to avoid:**
- **Use `SMAppService` (macOS 13+)** to register the background helper, not the legacy `~/Library/LaunchAgents/*.plist` pattern. The launch agent's plist and executable should live inside the main `.app` bundle (`Contents/Library/LaunchAgents/`). This is the supported modern path.
- **Onboarding screen explains the notification before it appears.** First-run UI: "macOS will show a 'Background item added' notification — this is the auto-wifi background service that lets the app keep monitoring when the window is closed." Show this *before* you call `SMAppService.agent(plistName:).register()`.
- **Provide an in-app toggle** that calls `register()` / `unregister()` so the user does not have to dig into System Settings. Reflect the current registration status (`.status`) live in the UI.
- **Minimize re-registration:** only call `register()` if status is not already `.enabled`. Repeated calls retrigger the notification.
- **Code-sign and notarize** the helper executable identically to the parent app — unsigned helpers are treated suspiciously and trigger extra warnings.

**Warning signs:**
- TestFlight/beta users complain about "Background item added" popping up repeatedly.
- The agent appears in System Settings > Login Items but is toggled off after a user restart.
- `launchctl list | grep auto-wifi` shows no entries on user machines even though it works in dev.

**Phase to address:** Phase 5 (background operation / LaunchAgent). Plan the SMAppService integration before writing the agent code; the agent architecture depends on it.

---

### Pitfall 7: Hardened runtime / notarization rejecting the build because of CoreWLAN + Location entitlements

**What goes wrong:**
The app builds and runs locally but fails notarization, or worse, ships to a user and immediately gets killed by Gatekeeper with no useful error. Or it runs but `associate(to:password:)` returns "operation not permitted" only on signed/notarized builds.

**Why it happens:**
- Notarization requires hardened runtime to be enabled.
- Hardened runtime restricts JIT, library loading, and certain system calls unless specific entitlement opt-outs are declared.
- CoreWLAN's `associate(to:password:)` requires the app to talk to `airportd` over XPC; sandboxed apps without `com.apple.security.network.client` and proper entitlements get cryptic "connection invalidated" errors.
- `NSLocationUsageDescription` purpose strings are checked at notarization-adjacent stages; a missing or empty string can cause silent permission failures.

**How to avoid:**
- **Disable App Sandbox** for v1. Sandbox + CoreWLAN association is a known fragile combination, and this is a personal/portfolio app distributed outside the Mac App Store, so sandbox is not required. Decide this explicitly and document it in PROJECT.md.
- **Enable hardened runtime** (required for notarization). Do not enable JIT, disable-library-validation, etc., unless something breaks — keep the entitlement surface minimal.
- **Required entitlements:**
  - `com.apple.security.network.client` (outbound network for health probes)
  - `com.apple.security.network.server` (only if you do listen() — probably not)
- **Required Info.plist keys:**
  - `NSLocationUsageDescription` AND `NSLocationWhenInUseUsageDescription` AND `NSLocationAlwaysAndWhenInUseUsageDescription` — all three with clear, distinct, non-empty strings. Missing any one of these has caused silent failures in shipped apps.
- **Notarize early, not last.** Set up the notarization pipeline (notarytool, stapler) in Phase 1, not Phase 7. Notarization failures discovered at ship time are panic-inducing; discovered early they are routine.
- **Test on a clean Mac**, not your dev machine. Your dev machine has cached approvals from Xcode runs; a fresh user will hit every prompt for the first time.

**Warning signs:**
- `codesign --verify --deep --strict --verbose=2 path/to/.app` reports issues.
- `xcrun notarytool log <uuid> --keychain-profile ...` shows specific entitlement complaints.
- App runs from Xcode but `associate()` fails when launched from `/Applications`.
- Console.app shows `airportd[xxx]: Client connection invalid` or `Sandbox: deny ...`.

**Phase to address:** Phase 1 (set up signing + hardened runtime + notarization scaffolding before any feature work). Re-verified at every phase boundary by running the full sign+notarize+install-on-clean-machine pipeline.

---

### Pitfall 8: Kicking the user off in the middle of a video call or upload

**What goes wrong:**
The user is on a Zoom call, ping latency spikes briefly, and the app helpfully disassociates and switches networks. The call drops. The user blames the app and never trusts it again. This is the single fastest way to lose user trust.

**Why it happens:**
Naive "switch when health degrades" logic does not know that the user is mid-call. A brief 200ms latency spike (totally normal on residential Wi-Fi) looks the same as a failing AP to a dumb scorer.

**How to avoid:**
- **Switches must be expensive.** Default minimum dwell time of 60-120 seconds after any switch.
- **Require sustained degradation:** at least 15-30 seconds of failed health probes (not a single failed ping) before considering a switch.
- **Active-connection awareness:** detect if there is meaningful active traffic on the interface (`getifaddrs` byte counters delta, or `nettop`-like sampling). If the user is transferring real data, raise the switch threshold significantly.
- **"Soft hold" hint:** A heuristic for "probably on a call" — sustained high bidirectional UDP traffic for >30s. While that hold is active, refuse to switch except on catastrophic loss (e.g., >50% loss over 30s).
- **User override:** A menubar item: "Pause auto-switching for 30 min." The user must have a panic button.
- **Confidence gating:** Do not switch unless the candidate is *substantially* better, not just better. The cost of being wrong is much higher than the cost of staying on a somewhat-worse network.

**Warning signs:**
- User reports "the app dropped my call."
- Decision log shows switches triggered by 1-3 failed probes.
- No "active traffic detected" considerations in switch decisions.

**Phase to address:** Phase 4 (health probing) and Phase 5 (switch decision logic — needs the cost-of-switch model and "pause auto-switch" UX).

---

### Pitfall 9: Switches happen invisibly and the user loses trust

**What goes wrong:**
Things change and the user does not know why. The Wi-Fi icon changes from one SSID to another silently. The user assumes it is macOS being weird, gets annoyed, opens the app, can't find an explanation, and uninstalls. Portfolio-wise: the decision log is the whole point — if it is not visible, the project's differentiator is invisible.

**Why it happens:**
Developers focus on "make the right decision" and forget that for a system that takes invisible automated actions, *explaining* the action is more important than making it. macOS itself is opaque about Wi-Fi switching, which is exactly the failure mode this app is supposed to fix — it must not replicate the same opacity.

**How to avoid:**
- **Native notification on every switch** with the reason: e.g., "Switched to HomeWiFi-5G — previous network (HomeWiFi-2.4G) RSSI -82 dBm and 4/5 pings failed; new network RSSI -54 dBm and reachable."
- **Menubar item shows current network and a one-glance status indicator** (green/yellow/red).
- **Decision log is first-class in the main window:** scrollable, filterable history with timestamp, from-network, to-network, scored values, and reason. This was called out explicitly in PROJECT.md as a portfolio feature.
- **Show *non-switch* decisions too:** "Considered switch to OfficeWiFi (-67 dBm) but rejected — improvement only 2 dB, below 6 dB hysteresis threshold." This is more interesting than just logging switches.
- **Decision tooltip on menubar hover:** show last decision instantly without opening the window.

**Warning signs:**
- User asks "why did it switch?" and the answer is not findable in the UI within 3 seconds.
- Notifications are off by default.
- The decision log is buried in a settings tab instead of front-and-center.

**Phase to address:** Phase 6 (UI / decision log) — but instrument decisions from Phase 3 onward. Every switch decision in the engine should already produce a structured record; the UI just renders it.

---

### Pitfall 10: Overriding a user's manual network choice

**What goes wrong:**
The user manually clicks "OfficeWifi" in the macOS Wi-Fi menu because they specifically want to use it (maybe the other network has a quota, or they're testing something). Five seconds later, the app switches them back to "HomeWifi" because it scored higher. The user is enraged.

**Why it happens:**
The app cannot tell the difference between "the OS auto-joined this network" and "the user just deliberately chose this network." Without that distinction, every switch the user makes gets reversed by the app's next scoring cycle.

**How to avoid:**
- **Detect manual joins:** observe `CWInterface` `linkDidChange` notifications combined with the absence of an app-initiated `associate()` call in the previous N seconds. If the SSID changes but the app did not initiate it, treat it as a manual user action.
- **"Manual hold" timer:** for ~10 minutes after a detected manual join, the app respects the choice and does not switch away, even if scoring says it should. The menubar item shows "User-selected: respecting choice for 9:47."
- **Make the hold cancellable** from the UI ("Resume auto-switching now") and adjustable in settings (5/10/30/60 min).
- **Treat manual-join as a signal**, not just an exception: log it. If a user repeatedly manually overrides the app's choice for the same SSID, surface that — maybe the scoring weights are wrong, or the user has a preference the app should learn.

**Warning signs:**
- User reports "I picked this network and the app forced me off."
- No detection mechanism for `linkDidChange` originating outside the app's own `associate()` calls.
- The app's switch log shows back-to-back: user-action → app-action reversal.

**Phase to address:** Phase 5 (switch decision logic). Manual-join detection must exist before auto-switching is enabled by default; ship it together.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Key all data structures by SSID (string) instead of BSSID | Simpler code, easier UI | Cannot distinguish 2.4 vs 5 GHz on same router; cannot detect roaming between APs of same SSID | Never — bake in BSSID keying from Phase 2 |
| Synchronous CoreWLAN calls on main thread | Easy to wire to SwiftUI | Scans block the UI for 1-5 seconds, UI freezes mid-scan | Only acceptable in earliest CLI spike; move off main thread before any UI work |
| `~/Library/LaunchAgents/*.plist` instead of `SMAppService` | One-off setup, no Xcode capability config | Triggers "Background item added" surprises; harder to uninstall; not the supported modern path | Never on macOS 13+ — use `SMAppService` from day one |
| Skip notarization for "internal builds" | Faster iteration | Real users can't run the build; signing problems are discovered late | OK during Phase 1 only; require notarized build at every phase boundary |
| Fixed scan interval | Trivial to implement | Battery drain, conflict with user traffic, complaints | Acceptable for v1 prototype; must become adaptive before public release |
| Log RSSI as raw value only | Easy to display | Cannot debug noise problems without smoothed-vs-raw comparison; users see jitter and lose confidence | Never — always store smoothed and raw side by side |
| One-sample switch decisions | Simple algorithm | Flapping — the exact problem the app is supposed to fix | Never — multi-sample dwell required from Phase 3 |
| Disable App Sandbox forever | Works around `associate()` issues | Will block any future Mac App Store distribution | Acceptable for v1 since PROJECT.md scopes out App Store; flag it explicitly |

---

## Integration Gotchas

Common mistakes when connecting to external services.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| CoreWLAN `scanForNetworks` | Calling on main thread in tight loop; assuming SSIDs are always present | Background queue, adaptive cadence, treat nil SSID as a "location permission denied" signal |
| CoreWLAN `associate(to:password:)` | Assuming it returns synchronously; not handling the case where it returns success but the connection silently fails to come up | Wait for `linkDidChange` notification with a 10-15 second timeout; if no link in that time, treat as failure and revert |
| CoreWLAN `disassociate()` | Using it as a "force roam" trigger; assuming it works on Wi-Fi 7 hardware | Avoid `disassociate()` as a primary mechanism — go directly `associate(to: newNetwork)` and let CoreWLAN handle the transition; known reliability issues on Wi-Fi 7 Macs |
| Apple Keychain (for stored Wi-Fi passwords) | Trying to read another app's keychain items | The system Wi-Fi keychain is owned by `airportd`; you cannot read passwords. Always call `associate(to:password:nil)` — CoreWLAN will pull credentials from the system store automatically for known networks |
| `captive.apple.com` probe | Using HTTPS (gets MITM'd or hung); not setting a tight timeout; trusting one probe | Use HTTP not HTTPS (this probe is intentionally HTTP), 3-5s timeout, require literal `"Success"` in body, retry once before concluding captive |
| Health probes (ping/DNS) | Pinging `8.8.8.8` only — fails on networks that block ICMP | Probe multiple things: TCP connect to 1.1.1.1:443, DNS lookup of `apple.com`, optional small HTTP GET. Require at least one to succeed |
| `SMAppService` registration | Calling `register()` on every app launch unconditionally | Check `.status` first; only register if not already `.enabled`; this avoids re-triggering the "Background item added" notification |
| Location authorization | Requesting at app launch before the user understands why | Explain in onboarding *first*, then trigger the prompt; provide a "Why does this need location?" link |

---

## Performance Traps

Patterns that work at small scale (one AP visible) but fail as scale grows (many APs / busy environments).

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Storing full scan history in memory forever | RAM growth over days of operation | Ring buffer (last N=1000 scan results) per BSSID; persist to SQLite/Core Data with TTL | After ~24h continuous run with 20+ visible APs |
| Recomputing scores for all networks on every UI tick | UI hitches | Compute scores only on new scan data; UI reads cached score | When >10 networks are visible and UI refresh is >1 Hz |
| Scanning every band sequentially on a tight loop | Heat, battery drain, traffic stalls | Adaptive cadence + scoped scans for `scanForNetworks(withName: knownSSID)` when re-checking a specific candidate | On battery, environments with >15 visible APs |
| Logging every RSSI sample to disk | Disk I/O, log file bloat, privacy footprint | Log at decision boundaries (switches, score crossings) not at every sample; rotating log files capped at e.g. 10 MB | After 1-2 weeks of operation |
| Spawning a new `Task` per scan | Task accumulation if a scan exceeds the cadence | Cancel previous in-flight scan task on new cadence tick, or use a serial queue | When scans start taking >scan-period in congested environments |
| Trusting cached `CWNetwork` results across long idle periods | Stale RSSI values informing decisions | Treat scan data older than 2-3x cadence as expired; force a fresh scan before any switch decision | When system was asleep/lid closed between scans |

---

## Security Mistakes

Domain-specific issues beyond general macOS app hardening.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Logging BSSIDs in plaintext to a file that gets synced to iCloud | BSSID list is a precise location signal — leaks user's home/work location to anyone with that file | Truncate BSSIDs in logs (`a1:b2:c3:**:**:**`) or hash them; exclude logs from any iCloud-synced location |
| Logging SSIDs in plaintext for support bundles | SSIDs often contain user names, addresses, or employer names | Redact SSIDs by default in exported diagnostic bundles; require explicit opt-in to include them |
| Storing scoring history forever | Multi-year location history derivable from BSSID timelines | TTL on stored scan data (e.g., 30 days); user-accessible "Clear history" button |
| Auto-joining unknown / open networks | Tracking, MITM, malicious portals | Out of scope per PROJECT.md — but enforce in code: never `associate()` to a network not already in `CWConfiguration.networkProfiles` |
| Reading the Wi-Fi password to copy/display it | Not actually possible (airportd owns it) but attempting it triggers TCC prompts and looks suspicious | Never try to read stored passwords — pass `nil` password to `associate()` and let CoreWLAN pull from system store |
| Disabled hardened runtime in shipped builds | Notarization fails; users can't run the app; security posture is weak | Enable hardened runtime; do entitlement opt-outs only where strictly required, and document why |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Switching networks silently | User feels the app is "doing things to them"; mistrust | Native notification with reason for every switch; menubar tooltip with last action |
| Burying the decision log in settings | The portfolio differentiator is invisible | Decision log is the primary content of the main window |
| Showing raw `dBm` only | -65 dBm means nothing to non-technical users | Show dBm AND a friendly indicator (Excellent/Good/Fair/Poor/Bad — with the dBm beside it) |
| Showing BSSID in primary UI | Users see `a4:b2:c3:...` and are confused | BSSID lives in a "Details" expander; SSID + band is the primary identity in main UI |
| No way to disable auto-switch | User in critical session needs an off-switch they can't find | Big "Pause auto-switching" toggle in menubar item; one click |
| Configuring hysteresis in dB at first launch | Most users do not know what 5 dB means | Ship sensible defaults (6 dB hysteresis, 3-sample dwell, 60s min interval); hide tuning in an Advanced panel |
| No first-run explanation of the Location Services prompt | User denies the permission and the app silently does nothing useful | Onboarding screen explains exactly what permission will be asked and why, *before* the system prompt fires |
| No "user picked this manually" detection | App reverts user's deliberate choices | Manual-join detection with a 10-minute respect window; visible in UI ("Respecting manual choice for 9:47") |
| Letting the app switch during active calls | Drops Zoom/Meet/FaceTime sessions | Active-traffic detection raises switch threshold; user-toggleable "Pause during meetings" |
| No way to mark a network "never auto-join" | User cannot prevent the app from picking the office guest network | Per-network preferences: prefer / avoid / never-auto-join — surfaced in network list rows |

---

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Network scanning:** Returns results — but verify SSID/BSSID are not nil. Run a clean install on a Mac that has never seen the app and confirm the Location prompt fires and SSIDs populate.
- [ ] **Switch algorithm:** Switches networks — but verify it does NOT flap. Leave the app running for 1 hour in a multi-AP environment; expect zero switches if the environment is stable.
- [ ] **Health checks:** Pings work — but verify they fail correctly on captive portals. Test on a real captive network (coffee shop, hotel).
- [ ] **Decision log:** Logs switches — but verify it also logs rejected switches with reasons ("considered but didn't switch").
- [ ] **LaunchAgent:** Registers at login — but verify it survives a reboot, that the "Background item added" notification fires exactly once not on every login, and that an in-app "Disable background agent" toggle actually unregisters cleanly.
- [ ] **Notifications:** Display on switch — but verify they include the *reason*, not just "Switched to HomeWifi."
- [ ] **Manual-join respect:** Detects manual network changes — but verify the respect window is visible in the UI and counts down, so the user knows the app is *intentionally* not acting.
- [ ] **Notarization:** Build succeeds — but verify the notarized `.app` runs on a *different* clean Mac without Gatekeeper warnings.
- [ ] **Hardened runtime:** Enabled — but verify `associate()` still works on the notarized signed build, not just in Xcode debug.
- [ ] **Captive portal handling:** Detects them — but verify the app actively *avoids* joining flagged captive networks, not just records that they are captive.
- [ ] **5GHz/2.4GHz disambiguation:** Distinct entries internally — but verify the UI does not duplicate the SSID for the user.
- [ ] **Battery:** Runs all day — but check Activity Monitor's Energy tab and confirm the app is not flagged "Significant Energy Use."
- [ ] **Active-call protection:** Heuristic in place — but verify by running a real Zoom call and confirming the switch threshold actually escalates.

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| SSID returns nil in production | LOW | Detect nil SSID in scan handler → show in-app remediation banner with "Open System Settings > Location Services" button (use `x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`) |
| Battery drain reports | LOW-MEDIUM | Ship cadence-config update; default cadence to a more conservative value; add Activity-Monitor-visible explanatory string in `Info.plist` |
| Flapping in the wild | MEDIUM | Raise hysteresis thresholds via update; add "Conservative mode" preset; expose the user-visible decision log so they can show you what's happening |
| Captive portal joined automatically | LOW | Detect via captive probe immediately after switch; auto-revert to previous network; mark current network captive in local store; surface in UI |
| User permanently disabled Login Items registration | LOW | Detect via `SMAppService.status`; show in-app banner "Background service is not running — re-enable?" with one-click re-register |
| Notarization rejected | MEDIUM | Read `notarytool log <uuid>`; almost always a missing entitlement, missing hardened-runtime flag, or unsigned nested binary; fix and resubmit |
| Switch during user's call | HIGH (trust damage) | Apologize in release notes; raise active-traffic threshold significantly; ship a default-on "Pause during active calls" feature; add a panic-pause button to the menubar |
| User reports the app switched them off their deliberate choice | MEDIUM | Add manual-join detection if not present; default respect window to 10 min; surface the respect state visibly |
| Wi-Fi 7 disassociate() not behaving | MEDIUM | Stop relying on `disassociate()`; use direct `associate(to: newNetwork)` as the primary transition mechanism (it implicitly disassociates from the previous one) |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| SSID nil without Location authorization | Phase 1 (foundations) | Clean-install test on a fresh Mac; assert SSID is non-nil after auth |
| Over-scanning battery drain | Phase 2 (scanning engine) | Activity Monitor energy reading after 1h continuous run |
| Network flapping | Phase 3 (scoring + hysteresis) | 1h soak test in a stable multi-AP environment; expect 0 switches |
| Captive portal auto-join | Phase 3-4 (scoring + health checks) | Manual test on coffee shop / hotel network; expect captive flag + score penalty + no auto-join |
| 5GHz vs 2.4GHz confusion | Phase 2 (data model) + Phase 3 (band as tiebreaker) | Unit test: same SSID, two BSSIDs with different band, verify selection prefers 5GHz only when RSSI within margin |
| LaunchAgent surprise notifications | Phase 5 (background operation) | Clean-install test; verify "Background item added" fires once and re-registration is idempotent |
| Hardened runtime / notarization failures | Phase 1 (signing scaffold) + every phase boundary | `xcrun notarytool submit` succeeds on every milestone build |
| Switch mid-call | Phase 4 (health probing) + Phase 5 (switch decision) | Real-call test: start Zoom, simulate brief degradation, verify no switch within active-traffic window |
| Invisible switches | Phase 3+ (decision instrumentation) + Phase 6 (UI) | UX review: every switch in the log must answer "why" in plain language |
| Overriding user's manual choice | Phase 5 (switch decision logic) | Test: manually pick a network in the menubar, confirm app respects it for the configured window |
| Stale stored scan data | Phase 2 (scanning) | Sleep/wake test: lid closed for 5 min, on wake verify a fresh scan happens before any switch decision |
| Logging privacy leakage | Phase 6 (UI/logging) or Phase 7 (polish) | Inspect exported diagnostic bundle; verify BSSIDs redacted by default |

---

## Sources

### macOS / CoreWLAN / Permissions
- [macOS get SSID changes? — Apple Developer Forums](https://developer.apple.com/forums/thread/732431)
- [CoreWLAN returning null SSID — Apple Developer Forums](https://developer.apple.com/forums/thread/748518)
- [CoreWlan network scan returns nil — Apple Developer Forums](https://developer.apple.com/forums/thread/124189)
- [MacOS - SSID attribute is Nil on Sonoma OS — Apple Developer Forums](https://developer.apple.com/forums/thread/737455)
- [Mac OS Sonoma SSID Info missing — Apple Developer Forums](https://developer.apple.com/forums/thread/744189)
- [Getting the Wi-Fi router BSSID — Apple Developer Forums](https://developer.apple.com/forums/thread/759044)
- [CoreWLAN returning None for SSID/BSSID (pyobjc issue #600)](https://github.com/ronaldoussoren/pyobjc/issues/600)
- [scanForNetworks(withName:) — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cwinterface/scanfornetworks(withname:))
- [disassociate() — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cwinterface/disassociate())
- [macOS Wifi Scanning — clburlison](https://clburlison.com/macos-wifi-scanning/)
- [Goodbye, airport! — Intuitibits (airport CLI deprecated in 14.4)](https://www.intuitibits.com/2024/03/14/goodbye-airport/)
- [airport -z no longer functions in 14.4 — Apple Developer Forums](https://developer.apple.com/forums/thread/748397)
- [Ask HN: Apple removed macOS ability to disassociate Wi-Fi from CLI](https://news.ycombinator.com/item?id=39701417)

### LaunchAgent / Background Items / Notarization
- [Manage login items and background tasks on Mac — Apple Support](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)
- [BackgroundTaskManagementAgent man page](https://keith.github.io/xcode-man-pages/backgroundtaskmanagementagent.8.html)
- [Login and Background Item Management in macOS Ventura 13 — n8felton](https://n8felton.wordpress.com/2022/10/24/login-and-background-item-management-in-macos-ventura-13/)
- [Technical Guide: Building a Modern Launch Agent on macOS — gist](https://gist.github.com/Matejkob/f8b1f6a7606f30777552372bab36c338)
- [macOS Ventura: Controlling Login and Background Items — Kandji](https://the-sequence.com/macos-ventura-login-background-items)
- [Hardened Runtime — Apple Developer Documentation](https://developer.apple.com/documentation/security/hardened-runtime)
- [Configuring the hardened runtime — Apple Developer Documentation](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [Resolving common notarization issues — Apple Developer Documentation](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Notarization: the hardened runtime — The Eclectic Light Company](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/)
- [macOS App Entitlements Guide — Medium](https://medium.com/@info_4533/macos-app-entitlements-guide-b563287c07e1)

### Roaming / Hysteresis / RSSI Smoothing
- [RSSI, Roaming, and Fast Roaming — Juniper Networks/Mist](https://www.juniper.net/documentation/us/en/software/mist/mist-wireless/topics/topic-map/rssi-fast-roaming.html)
- [Mysteries of client roaming revealed — 7SIGNAL whitepaper](https://cdn2.hubspot.net/hubfs/353374/Knowledge%20Base/MYSTERIES%20of%20Wi-Fi%20Roaming%20Revealed%20-%207SIGNAL%20Whitepaper.pdf)
- [Optimized Roaming — Cisco](https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/config-guide/b_wl_16_10_cg/optimized-roaming.pdf)
- [Revolution Wi-Fi: Optimized Roaming, RSSI Low Check, RX-SOP](https://revolutionwifi.blogspot.com/2014/08/optimized-roaming-rssi-low-check-rx-sop.html)
- [Wi-Fi Roaming Sticky Clients: Minimum RSSI and Band Steering — Digitech Bytes](https://digitechbytes.com/troubleshooting-optimization/fix-sticky-wifi-clients/)
- [Cisco Wireless Controller Client Roaming Configuration Guide](https://www.cisco.com/c/en/us/td/docs/wireless/controller/8-5/config-guide/b_cg85/client_roaming.html)
- [Kalman filters explained: Removing noise from RSSI signals — Wouter Bulten](https://www.wouterbulten.nl/posts/kalman-filters-explained-removing-noise-from-rssi-signals/)
- [Advanced Smoothing Approach of RSSI and LQI for Indoor Localization](https://journals.sagepub.com/doi/10.1155/2015/195297)
- [WiFi network selection based on RSSI velocity](https://www.tdcommons.org/cgi/viewcontent.cgi?article=2867&context=dpubs_series)
- [Band Steering — Cisco Meraki Documentation](https://documentation.meraki.com/Wireless/Operate_and_Maintain/User_Guides/Radio_Settings/Band_Steering)

### Captive Portals
- [Captive portal — Wikipedia](https://en.wikipedia.org/wiki/Captive_portal)
- [How to modernize your captive network — Apple Developer](https://developer.apple.com/news/?id=q78sq5rv)
- [What is captive.apple.com/hotspot-detect.html — Apple Community](https://discussions.apple.com/thread/7491051)
- [Captive Network Assistant — Apple Developer Forums](https://developer.apple.com/forums/thread/62947)
- [Captive portal detection — Apple Developer Forums](https://developer.apple.com/forums/thread/747798)
- [Captive Portals — text/plain](https://textslashplain.com/2022/06/24/captive-portals/)

### SwiftUI Menubar / App Distribution
- [Build a macOS menu bar utility in SwiftUI — nilcoalescing](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)
- [Create a mac menu bar app in SwiftUI with MenuBarExtra — Sarunw](https://sarunw.com/posts/swiftui-menu-bar-app/)
- [Swift Protip: Hiding Your App's Icon From the Dock Properly](https://buresdv.substack.com/p/swift-protip-hiding-your-apps-icon)

---
*Pitfalls research for: macOS WiFi auto-switching GUI app*
*Researched: 2026-05-12*
