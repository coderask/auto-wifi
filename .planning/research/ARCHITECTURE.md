# Architecture Research

**Domain:** Native macOS menubar/agent utility — continuous WiFi monitoring + automated network switching
**Researched:** 2026-05-12
**Confidence:** MEDIUM-HIGH (process model + IPC: HIGH; CoreWLAN scan cadence specifics: MEDIUM — exact rate limits poorly documented; hysteresis algorithm: HIGH — well-established roaming literature)

---

## Executive Architectural Decisions

Five "if you only read one section" decisions, with confidence and rationale:

| Decision | Recommendation | Confidence | Why |
|---|---|---|---|
| **Process model** | **Single-bundle app with embedded SMAppService LaunchAgent** | HIGH | Modern macOS 13+ pattern. Agent plist + binary live inside the `.app`, code-signed as one unit, surfaces correctly in System Settings → Login Items. Avoids legacy scattered-files installer. |
| **GUI ↔ Agent IPC** | **NSXPCConnection over a launchd MachServices endpoint** | HIGH | Type-safe, lifecycle-managed by launchd, on-demand activation, privilege-separated. The other options (Distributed Notifications, shared UserDefaults, files) each lose either type safety, request/reply semantics, or push notifications. |
| **Monitoring loop concurrency** | **One Swift actor per concern** (`ScanActor`, `HealthActor`, `DecisionActor`, `SwitchActor`), coordinated via `AsyncStream` channels | HIGH | CoreWLAN is **not thread-safe**, so single-actor serialization of all CWInterface calls is mandatory. Actors give Swift 6-clean concurrency without GCD bookkeeping. |
| **State exposure to GUI** | **`@Observable` snapshot object in GUI process**, updated from XPC notifications carrying small `Codable` deltas | HIGH | SwiftUI reacts to `@Observable` natively; XPC ferries structured updates; no shared mutable state across processes. |
| **Persistence** | **SwiftData for the decision log + per-network preferences; plain JSON in App Group for runtime tuning knobs** | MEDIUM | SwiftData fits the relational decision-log shape and gets actor-based concurrency for free on macOS 14+. JSON in the App Group container is the cheapest path for live config the agent re-reads on change. |

---

## System Overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          USER-FACING PROCESS                                │
│  (auto-wifi.app — LSUIElement=true, NSApplication.accessory policy)         │
│                                                                              │
│   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────┐    │
│   │  MenuBarExtra    │   │  Main Window     │   │  Settings Scene      │    │
│   │  (status, on/off)│   │  (live metrics,  │   │  (thresholds, dwell, │    │
│   │                  │   │   decision log)  │   │   per-network prefs) │    │
│   └────────┬─────────┘   └────────┬─────────┘   └──────────┬───────────┘    │
│            │                      │                        │                 │
│            └──────────┬───────────┴────────────────────────┘                 │
│                       │                                                       │
│                ┌──────▼─────────┐    Observable snapshot                     │
│                │  ViewModel(s)  │    (current SSID, candidates, decisions)   │
│                └──────┬─────────┘                                            │
│                       │                                                       │
│                ┌──────▼─────────┐                                            │
│                │ AgentClient    │  ──── NSXPCConnection ────┐                │
│                │ (XPC proxy)    │                            │                │
│                └────────────────┘                            │                │
└──────────────────────────────────────────────────────────────┼───────────────┘
                                                               │
                                       Mach service: com.aarnavk.autowifi.agent
                                                               │
┌──────────────────────────────────────────────────────────────┼───────────────┐
│                        BACKGROUND AGENT PROCESS                              │
│  (auto-wifi-agent — launched on demand by launchd via SMAppService)         │
│                                                                              │
│                ┌──────────────────┐                                          │
│                │ XPCListener      │  exposes AgentProtocol to GUI            │
│                │  (NSXPCListener) │  + push channel via remote proxy         │
│                └────────┬─────────┘                                          │
│                         │                                                     │
│                ┌────────▼──────────────────────────────┐                     │
│                │         CoordinatorActor              │                     │
│                │  - owns state machine                 │                     │
│                │  - publishes AsyncStream of events    │                     │
│                └─┬─────────┬─────────┬──────────┬──────┘                     │
│                  │         │         │          │                            │
│           ┌──────▼──┐ ┌────▼────┐ ┌──▼──────┐ ┌─▼──────────┐                 │
│           │ Scan    │ │ Health  │ │Decision │ │  Switch    │                 │
│           │ Actor   │ │ Actor   │ │ Actor   │ │  Actor     │                 │
│           │         │ │         │ │         │ │            │                 │
│           │ CW scan │ │ NWPath  │ │ scoring │ │  CWInterface│                │
│           │ + cache │ │ + ping  │ │ + EMA   │ │ .associate │                 │
│           │ + RSSI  │ │ + DNS   │ │ +hyster.│ │            │                 │
│           └────┬────┘ └────┬────┘ └────┬────┘ └─────┬──────┘                 │
│                │           │           │            │                        │
│                └───────────┴─────┬─────┴────────────┘                        │
│                                  │                                            │
│                     ┌────────────▼──────────────┐                            │
│                     │  CoreWLAN subsystem        │                            │
│                     │  (CWWiFiClient singleton,  │  ─ events: scanCacheUpdated│
│                     │   CWEventDelegate)         │           linkDidChange    │
│                     └────────────┬──────────────┘                            │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   │
                          macOS Wi-Fi driver / locationd
                                   │
                              ╔════╧════╗
                              ║  Radio  ║
                              ╚═════════╝

┌────────────────────────────────────────────────────────────────────────────┐
│                          PERSISTENCE LAYER                                  │
│  Container: ~/Library/Group Containers/group.com.aarnavk.autowifi/          │
│                                                                              │
│   ┌────────────────────┐  ┌──────────────────────┐  ┌─────────────────┐    │
│   │  SwiftData store   │  │  config.json         │  │  Logs (OSLog)   │    │
│   │  (decision log,    │  │  (thresholds, dwell, │  │  unified system │    │
│   │   per-network      │  │   per-network prefs  │  │  log subsystem  │    │
│   │   metrics history) │  │   — agent watches    │  │                 │    │
│   │                    │  │   for changes)       │  │                 │    │
│   └────────────────────┘  └──────────────────────┘  └─────────────────┘    │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Component | Owner Process | Responsibility |
|---|---|---|
| `MenuBarExtra` | GUI | Persistent status icon (current SSID, signal bars, state-machine color), quick toggle for auto-switching |
| Main window | GUI | Live dashboard: current network + measurements, scanned candidates with scores, decision history |
| `Settings` scene | GUI | Tuning UI: hysteresis margin, dwell timers, per-network priority/blocklist |
| `AgentClient` | GUI | Thin XPC proxy. Vends an `@Observable` snapshot the views bind to. Reconnects on agent restart. |
| `XPCListener` | Agent | Single Mach endpoint. Exposes `AgentProtocol` (request/reply) and accepts a `GUIObserverProtocol` proxy for push updates. |
| `CoordinatorActor` | Agent | Top-level orchestrator. Owns the connection state machine. Fans out events to the GUI. Holds the singleton `CWWiFiClient`. |
| `ScanActor` | Agent | Serializes all `CWInterface.scanForNetworks(...)` calls. Listens to `scanCacheUpdated` for free deltas. Emits `[ScanResult]` snapshots. |
| `HealthActor` | Agent | Runs `NWPathMonitor` + cadenced ICMP/TCP/DNS probes against the *currently associated* network. Emits `HealthSample` events with latency, loss, DNS success. |
| `DecisionActor` | Agent | Pure-ish function. Consumes scan + health streams, maintains per-network EMAs, runs hysteresis + scoring, emits `Decision { stay | switchTo(SSID) }`. |
| `SwitchActor` | Agent | Performs `CWInterface.associate(...)`. Enforces cooldown after a switch. Reports outcome (success/failure + new BSSID). |
| `PersistenceActor` | Agent | SwiftData `ModelActor`. Writes decision-log entries; serves history queries from the GUI. |
| `ConfigStore` | Both | Reads `config.json` from the App Group container; agent uses `DispatchSource` file-watcher to pick up GUI-side edits without restart. |

---

## Detailed Decisions

### 1. Process Model — SMAppService LaunchAgent embedded in the app

**Three options were on the table:**

1. **Single app with internal background loop, no agent.** Kill it when the GUI closes → fails the requirement.
2. **Classic LaunchAgent**: separate binary in `/usr/local/bin`, plist hand-installed into `~/Library/LaunchAgents`. Legacy; scattered files; broken in sandboxed apps; opaque to users.
3. **SMAppService (macOS 13+) — recommended.** The agent's binary lives at `Contents/MacOS/auto-wifi-agent` inside the app bundle, and its launchd plist at `Contents/Library/LaunchAgents/com.aarnavk.autowifi.agent.plist`. The GUI calls `SMAppService.agent(plistName:).register()`.

**Why SMAppService wins for this project:**
- The whole `.app` is code-signed and notarized as one artifact — no separate installer.
- Surfaces in **System Settings → General → Login Items** under the app's name; users can disable cleanly.
- Target is macOS 14+ (per `PROJECT.md`), well past the early Ventura 13.0/13.1 SMAppService bugs.
- The agent runs as the user (not root) — sufficient because CWInterface.associate doesn't need elevation (Keychain has the credentials already).
- No need for SMJobBless or `SMLoginItemSetEnabled` (both deprecated in macOS 13).

**Plist essentials for the agent:**
- `KeepAlive = true` (with `Crashed = true`) so it auto-restarts.
- `MachServices = { "com.aarnavk.autowifi.agent" = true }` to expose the XPC endpoint.
- `RunAtLoad = false` — let launchd start it on demand when the GUI first connects, then `KeepAlive` keeps it up.
- No `StartInterval` — internal scheduling lives in the actors, not launchd.

**Confidence:** HIGH on the recommendation, MEDIUM on whether macOS 14.4+ adds any new SMAppService friction; the Apple dev forums show isolated error-125 reports for specific provisioning shapes but nothing blocking a developer-signed standalone app.

### 2. IPC — NSXPCConnection (with Distributed Notifications and shared UserDefaults explicitly *not* used for control flow)

The IPC choice is the single most consequential architectural decision because it constrains:
- How richly the GUI can subscribe to live state.
- Whether you can preserve type safety across the process boundary.
- How the agent gets started and how it dies.

**Pattern comparison for this app:**

| Pattern | Push GUI updates? | Type-safe? | Request/reply? | Launchd-integrated? | Fit |
|---|---|---|---|---|---|
| **NSXPCConnection** | Yes (remote proxy back to GUI) | Yes (`@objc` protocols) | Yes | Yes (via MachServices) | **Best fit** |
| Distributed Notifications | Yes (broadcast) | No (dict payloads) | No | No | Auxiliary use only |
| App Group + UserDefaults + KVO | Polling-ish (KVO doesn't cross processes natively) | No | No | No | Config only |
| App Group + shared file + DispatchSource | Yes (file watch) | If JSON+Codable | No | No | Config + maybe state cache fallback |
| App Group + Unix domain socket | Yes | Manual | Manual | No | Reinventing XPC |

**Recommended layout:**

```swift
@objc protocol AgentProtocol {
    func currentSnapshot() async -> Data            // Codable State snapshot
    func setAutoSwitch(enabled: Bool) async
    func updateThresholds(_ data: Data) async       // Codable Thresholds
    func forceRescan() async
    func subscribe(observer: GUIObserverProtocol)   // GUI registers its proxy
}

@objc protocol GUIObserverProtocol {
    func didUpdate(snapshotData: Data)              // small delta payloads
    func didDecide(eventData: Data)
}
```

The GUI creates an `NSXPCConnection` to the Mach service, sets `remoteObjectInterface`, sets *its own* `exportedInterface` to `GUIObserverProtocol`, and calls `subscribe(observer:)`. The agent gets a remote proxy back into the GUI for push updates. This is the same shape Apple uses for many of its own daemon/GUI pairs.

**Where the lesser patterns still earn a place:**
- **App Group + JSON config file**: tuning knobs the user changes from Settings. The GUI writes the file; the agent's `DispatchSource.makeFileSystemObjectSource` picks up the change and re-reads. Survives agent restarts trivially.
- **Distributed Notifications**: optional, for very coarse events you may want to fan out beyond the GUI (e.g., a future Shortcuts action observer).
- **OSLog**: not strictly IPC, but `Logger(subsystem:category:)` from the agent shows up in Console.app and `log stream` for debugging.

**Anti-patterns to avoid:**
- **Polling UserDefaults across processes.** `KVO` on `UserDefaults` does *not* fire reliably across the process boundary on macOS — the OS may coalesce or drop notifications. Don't build live UI on this.
- **Using XPC Services (the bundled `.xpc` kind) instead of a launchd agent.** XPC Services are tied to the lifetime of the calling app; the agent must outlive the GUI window.

**Confidence:** HIGH. NSXPCConnection + MachServices is the textbook Apple pattern for a long-lived helper that a GUI talks to.

### 3. Core Monitoring Loop

#### 3a. Scan scheduler — adaptive, event-driven first, polled second

CoreWLAN scanning is **expensive**: it triggers `locationd`, briefly disrupts the data path on the radio, and is rate-limited inside the framework (community lore says ~10s minimum between active scans; precise limits are undocumented). Strategy:

1. **Always-on event subscription.** Register the `CWEventDelegate` for `scanCacheUpdated` and `linkDidChange` at startup. The Wi-Fi subsystem already does background scans for its own roaming; consume those for free via `CWInterface.cachedScanResults()`.
2. **Adaptive active scan cadence.** Use a state-machine-driven interval, not a fixed timer:

   | State | Active scan interval | Rationale |
   |---|---|---|
   | `STEADY` (healthy) | 60–120 s | Conserve power and radio time; rely on cache + events. |
   | `DEGRADED` (health failing) | 10–15 s | Find escape route quickly. |
   | `SWITCHING` | suspended | Don't scan while associating. |
   | `COOLDOWN` (just switched) | 30 s | Let DHCP settle, prevent thrash. |
   | On manual user request | immediate (but rate-limited) | "Rescan now" button. |

3. **Serialize all CW calls in `ScanActor`.** CoreWLAN is not thread-safe; an actor is the cleanest enforcement.
4. **Honor the 10s minimum gap** with a `lastScanAt` guard inside the actor.

#### 3b. Health-check scheduler — cheap, fast, layered

Health probes target the *currently associated* network only (you cannot probe candidate APs without joining them). Layered:

| Probe | Cadence | Tool | What it catches |
|---|---|---|---|
| `NWPathMonitor` | event-driven | Network framework | Interface up/down, gateway changes |
| DNS lookup of known host | 5 s | `DNSServiceRef` / `getaddrinfo` on a queue | DNS server reachability |
| ICMP-equivalent ping | 2 s | `NWConnection` UDP to gateway w/ timeout, or raw ICMP if entitled | RTT, packet loss |
| Throughput sample | every 60 s, or on demand | Small HTTPS GET to a known-good endpoint | Real bandwidth (cheap version) |
| Captive portal hint | on associate | HTTP to `captive.apple.com` | Avoids declaring a captive net "healthy" |

The `HealthActor` maintains a sliding-window state per probe and emits a `HealthSample` event whenever a sample completes. The decision actor consumes these.

#### 3c. State machine

```
       ┌───────────────────────────────────────────────────────────┐
       │                                                           │
       │       (user disables auto-switch)                         │
       ▼                                                           │
   ┌───────┐                                                       │
   │  OFF  │◀──────────────────────────────────────────────────────┤
   └───┬───┘                                                       │
       │ (user enables)                                            │
       ▼                                                           │
   ┌─────────┐  health OK + RSSI > floor   ┌──────────┐            │
   │ STEADY  │ ──────────────────────────▶ │  STEADY  │            │
   │         │ ◀──────────────────────────                          │
   └────┬────┘   (loop)                                            │
        │                                                          │
        │ health degraded OR RSSI < floor (sustained, dwell met)   │
        ▼                                                          │
   ┌──────────┐  better candidate scored, margin met, dwell met    │
   │ DEGRADED │ ───────────────────────────────────────────────┐   │
   │          │                                                │   │
   │          │ recovery (health restored, dwell met)          │   │
   │          │ ─────────────▶  STEADY                         │   │
   └────┬─────┘                                                │   │
        │                                                      │   │
        │ no candidate yet                                     │   │
        │ (keep scanning at DEGRADED cadence)                  │   │
        ▼                                                      ▼   │
   (stay DEGRADED)                                       ┌─────────┐│
                                                         │SWITCHING││
                                                         └────┬────┘│
                                                              │     │
                                  associate success ──────────┤     │
                                                              ▼     │
                                                         ┌──────────┴┐
                                                         │ COOLDOWN  │
                                                         │ (30s,     │
                                                         │  no decisions)
                                                         └─────┬─────┘
                                                               │
                                                               ▼
                                                            STEADY
```

#### 3d. Hysteresis math (this is the project's signature)

Three layers of hysteresis, each independently tunable:

1. **Sample smoothing — Exponential Moving Average on per-network RSSI and per-probe latency.**
   `ema_new = α * sample + (1 - α) * ema_old`, with α ≈ 0.3 (responsive but not jittery). Per BSSID for RSSI; per probe for health.

2. **Threshold hysteresis — bands, not lines.** Two thresholds for each metric:
   - RSSI: `goodEnough = -67 dBm`, `tooWeak = -75 dBm`. STEADY→DEGRADED requires crossing `tooWeak`; DEGRADED→STEADY requires crossing `goodEnough`. The 8 dB band prevents oscillation around the threshold.
   - Latency: `goodEnough = 60 ms`, `tooSlow = 250 ms` (or N consecutive timeouts).

3. **Dwell timers — time-based hysteresis.** A condition must hold continuously for a dwell period before a transition fires:
   - `degradeDwell`: 10 s — current network must be bad continuously before we even start looking.
   - `candidateDwell`: 8 s — a candidate must remain better continuously before we switch.
   - `switchMargin`: candidate's score must beat current network's score by ≥ 15 points (out of 100) — prevents flapping between near-equals.
   - `postSwitchCooldown`: 30 s — no further switches in this window, regardless of metrics.

All five numbers above belong in `config.json` so the user can tune them and (per PROJECT.md) at minimum *see* them.

#### 3e. Decision engine — scoring

Each candidate (current network included) gets a score in [0, 100]:

```
score(net) = w_rssi   * rssi_score(ema_rssi(net))
           + w_health * health_score(net)            // current net only; candidates get a neutral prior
           + w_pref   * preference_score(net)        // user-set priority / penalty
           + w_band   * band_bonus(net)              // mild 5GHz/6GHz preference
           - penalty_recent_failure(net)
```

Decision rule:
1. If `score(current) >= goodEnoughFloor` → stay (no scan-based switch).
2. Else find `best = argmax score(candidate ≠ current)`.
3. If `best.score - current.score >= switchMargin` AND `best` held that lead for `candidateDwell` → switch.

This deliberately decouples *when to look* (state machine) from *what to choose* (scoring) — two clean concerns, both testable in isolation.

**Confidence:** HIGH on the algorithm shape (this is standard roaming literature applied to a single host). The specific constants are starting points; the project's decision-log feature is exactly what calibrates them.

### 4. Data Flow — reactive within the agent, structured push to the GUI

**Inside the agent** (Swift Concurrency, no Combine):

```
CWEventDelegate ──► ScanActor      ─┐
                                    ├──► AsyncStream<CoordinatorEvent> ──► CoordinatorActor
NWPathMonitor   ──► HealthActor    ─┘                                          │
ConfigStore.changes ───────────────────────────────────────────────────────────┤
                                                                               ▼
                                                                       DecisionActor
                                                                               │
                                                                               ▼
                                                                        SwitchActor
                                                                               │
                                                                               ▼
                                                            PersistenceActor (log entry)
                                                                               │
                                                                               ▼
                                                            XPCListener.broadcast(snapshot)
```

Each actor exposes an `AsyncStream` of typed events. `CoordinatorActor` is the single subscriber to all of them and the single source of truth for "current state." It compiles a `Snapshot` value on each transition and pushes it through XPC.

**Why AsyncStream over Combine here:** the agent has no UI, no `@Published`, and benefits from actor-isolated event flow that the compiler can reason about under Swift 6 strict concurrency. Combine would add a framework dependency for no gain. Swift 6.2's `Observations` async-sequence type makes this even cleaner if available.

**In the GUI**, the picture flips: SwiftUI wants `@Observable`. So the GUI side has:

```swift
@Observable
final class AppState {
    var current: NetworkSnapshot?
    var candidates: [CandidateSnapshot] = []
    var state: ConnectionState = .off
    var recentDecisions: [DecisionEntry] = []
}
```

`AgentClient` decodes each XPC push and mutates `AppState` on the main actor. Views bind directly. No Combine pipelines.

**Key data flows:**

1. **Live status flow (push):** CW event → ScanActor → Coordinator → XPC push → AppState mutation → MenuBarExtra/window re-render. End-to-end < 100 ms typical.
2. **User toggle (request):** Toggle in GUI → AgentClient → XPCProtocol.setAutoSwitch → CoordinatorActor flips state → snapshot push → GUI confirms.
3. **Threshold edit (config flow):** Settings UI → write `config.json` in App Group → agent's `DispatchSource` file-watcher fires → ConfigStore re-parses → Coordinator publishes new thresholds.
4. **Decision log (query/pull):** GUI requests page of history → AgentClient → XPCProtocol.fetchDecisions(range:) → PersistenceActor SwiftData query → returns `[DecisionEntry]`.

### 5. Persistence — SwiftData for structured history, JSON for config, OSLog for diagnostics

| Data | Where | Why |
|---|---|---|
| Decision log entries (`when`, `from`, `to`, `reason`, `scoresAtDecision`) | **SwiftData** in App Group container | Relational + queryable + Codable models; native `ModelActor` for safe agent-side writes; SwiftUI can bind list views straight to a `@Query` if the GUI ever queries the same store, but XPC-mediated reads keep concurrency simple. |
| Per-network preferences (priority, blocklist, last-known-good metrics) | **SwiftData** in same store | Naturally relational with decision entries via SSID. |
| Tuning thresholds + auto-switch on/off | **JSON in App Group container** | Tiny, human-readable, easy to ship defaults with the app, easy to backup/restore, agent file-watches for live edits. |
| Runtime diagnostics | **OSLog** (`Logger(subsystem: "com.aarnavk.autowifi", category: ...)`) | Free, structured, searchable in Console.app and `log stream`. Not user-visible UI but invaluable for portfolio-grade debugging. |

**Why SwiftData over Core Data:** the project targets macOS 14+, so SwiftData's macOS 14 minimum is fine. SwiftData wraps Core Data under the hood; you keep the maturity of Core Data's store but get model definitions in plain Swift, `ModelActor` for principled concurrency, and a substantially smaller surface area. Core Data would still work but requires manual `NSManagedObjectContext` discipline that SwiftData handles via actors.

**Why not put thresholds in SwiftData:** they're singletons, edited rarely, and you want file-watch semantics for cross-process updates without polling the store.

**Confidence:** MEDIUM. SwiftData has matured in 2024-2026 but historically had rough edges around schema migration and CloudKit sync. For local-only single-store usage it is well within its sweet spot. Fallback to plain JSON files for the decision log is a fine v0 if SwiftData proves troublesome — the model abstraction in `PersistenceActor` makes the swap cheap.

---

## Recommended Project Structure

```
auto-wifi/
├── auto-wifi.xcworkspace
├── App/                              # GUI target (auto-wifi.app)
│   ├── auto_wifiApp.swift            # @main, MenuBarExtra, WindowGroup, Settings scenes
│   ├── AppState.swift                # @Observable root state
│   ├── AgentClient.swift             # NSXPCConnection wrapper, reconnect logic
│   ├── AgentLifecycle.swift          # SMAppService register/unregister
│   ├── Views/
│   │   ├── MenuBarContent.swift
│   │   ├── DashboardView.swift       # current + candidates table
│   │   ├── DecisionLogView.swift
│   │   ├── SettingsView.swift        # thresholds, dwell, per-network prefs
│   │   └── Components/               # SignalBars, ScoreBadge, etc.
│   └── Resources/
│       └── Info.plist                # LSUIElement=true, NSLocationUsageDescription
│
├── Agent/                            # auto-wifi-agent (bundled at Contents/MacOS/)
│   ├── main.swift                    # XPCListener.shared.resume() + RunLoop.run()
│   ├── XPCListener.swift
│   ├── AgentService.swift            # implements AgentProtocol
│   ├── Actors/
│   │   ├── CoordinatorActor.swift    # state machine + event fan-in
│   │   ├── ScanActor.swift           # CWInterface scans + cache + events
│   │   ├── HealthActor.swift         # NWPathMonitor + probes
│   │   ├── DecisionActor.swift       # scoring + hysteresis math
│   │   ├── SwitchActor.swift         # CWInterface.associate, cooldown
│   │   └── PersistenceActor.swift    # SwiftData ModelActor
│   ├── ConfigStore.swift             # JSON read + DispatchSource file watch
│   └── Resources/
│       └── com.aarnavk.autowifi.agent.plist
│
├── Shared/                           # framework or sources shared by both targets
│   ├── IPC/
│   │   ├── AgentProtocol.swift       # @objc protocol
│   │   ├── GUIObserverProtocol.swift
│   │   └── DTOs/                     # Codable Snapshot, Decision, Thresholds, …
│   ├── Models/
│   │   ├── NetworkSnapshot.swift
│   │   ├── HealthSample.swift
│   │   └── ConnectionState.swift
│   ├── Algorithms/
│   │   ├── EMA.swift
│   │   ├── ScoringEngine.swift       # PURE, fully unit-testable
│   │   └── Hysteresis.swift          # thresholds, dwell, switchMargin
│   └── Logging/
│       └── Log.swift                 # OSLog wrappers per subsystem
│
├── Tests/
│   ├── ScoringEngineTests.swift      # pure-logic tests — easy to land first
│   ├── HysteresisTests.swift         # dwell timer + threshold band tests
│   ├── DecisionActorTests.swift      # actor-based scenario replay
│   └── XPCFixtures/                  # in-process XPC test harness
│
└── .planning/                        # GSD planning artifacts
```

**Structure rationale:**

- **`App/` vs `Agent/` separation enforces the process boundary at the source level.** No accidental cross-imports — anything they share goes through `Shared/`.
- **`Shared/Algorithms/` is the testable core.** The scoring + hysteresis logic must be pure Swift (no CoreWLAN, no Network framework imports), so it can be unit-tested with synthetic inputs. This is where the decision log earns its keep — every entry is a regression test fixture.
- **`Shared/IPC/DTOs/`**: kept dumb Codable structs, no behavior. Both processes own the same versions.
- **`Agent/Actors/` matches the architecture diagram 1:1** so the codebase is navigable from the diagram.

---

## Architectural Patterns

### Pattern 1: Single-actor wrapper around an unsafe framework

**What:** Wrap each non-thread-safe Apple framework (CoreWLAN especially) in a dedicated Swift actor. All access to that framework goes through the actor.

**When to use:** CoreWLAN, plus any C API that documents thread-affinity requirements.

**Trade-offs:** All access is serialized — fine here because the radio is the bottleneck anyway. Cost is one `await` per call. Benefit is total Swift 6 concurrency-checked safety.

**Example:**
```swift
actor ScanActor {
    private let client = CWWiFiClient.shared()
    private var lastScanAt: ContinuousClock.Instant = .now - .seconds(60)
    private let minGap: Duration = .seconds(10)

    func scan(force: Bool = false) async throws -> [CWNetwork] {
        let now = ContinuousClock.now
        if !force, now - lastScanAt < minGap {
            return Array(client.interface()?.cachedScanResults() ?? [])
        }
        lastScanAt = now
        let iface = client.interface()
        return try Array(iface?.scanForNetworks(withName: nil) ?? [])
    }
}
```

### Pattern 2: Coordinator owns the state machine; everyone else is dumb

**What:** A single `CoordinatorActor` owns `ConnectionState` and all transitions. Other actors emit *facts* (a scan completed; a health sample arrived; the user toggled auto-switch). The coordinator interprets facts into transitions.

**When to use:** Any system with a small finite state space and multiple input sources.

**Trade-offs:** Concentrates complexity in one place (good for review and debugging; bad if it grows past a few hundred lines — split the FSM into a separate `StateReducer` type when that day comes).

### Pattern 3: Snapshot-over-XPC with versioned DTOs

**What:** Never share live objects across processes. Always serialize a `Codable` snapshot.

**When to use:** Every XPC call between the GUI and agent.

**Trade-offs:** Slight redundancy compared to mutable shared state, but eliminates entire classes of bugs (stale references, dangling proxies, concurrency races across processes). Add a `protocolVersion: Int` field to DTOs from day one — you will change them.

### Pattern 4: Event-driven scanning preferred to polling

**What:** Subscribe to `CWEventDelegate.scanCacheUpdated` and `linkDidChange` as the primary source of fresh data; treat active `scanForNetworks` calls as a backup the state machine triggers when freshness is insufficient.

**When to use:** Any time the OS already publishes events you'd otherwise poll for.

**Trade-offs:** Event coverage may be incomplete (the OS may suppress events when locationd is busy), so you still need a polling fallback. But the *average* power and CPU cost drops dramatically.

### Pattern 5: Pure-logic core, side-effecting shell

**What:** The scoring engine and hysteresis math live in `Shared/Algorithms/` with **zero framework dependencies** — they take `(scan: [ScanSample], health: HealthSample, prefs: Prefs, prior: DecisionState) -> Decision` and return a decision. The actor shell does the I/O.

**When to use:** Whenever a system has subtle business logic worth testing without spinning up the radio.

**Trade-offs:** None for this project — this is the right shape. It makes property-based testing on the hysteresis trivial and is exactly what makes the decision log a portfolio asset rather than a debugging crutch.

---

## Data Flow Detail

### Decision flow (the most important sequence)

```
[CWWiFiClient event: scanCacheUpdated]
        │
        ▼
ScanActor.handle(event) ──► snapshot built from cachedScanResults
        │
        ▼  (AsyncStream<ScanUpdate>)
CoordinatorActor.onScan(update)
        │
        ├──► merge with latest HealthSample
        │
        ▼
DecisionActor.evaluate(scan, health, config, priorState) → Decision
        │
        ├── Decision.stay              ──► no-op, snapshot push
        │
        └── Decision.switchTo(SSID)
                │
                ▼
        Coordinator.transition(.SWITCHING)
                │
                ▼
        SwitchActor.associate(SSID)  ── CWInterface.associate(...)
                │
                ▼
        PersistenceActor.record(decision)
                │
                ▼
        Coordinator.transition(.COOLDOWN)
                │
                ▼
        XPCListener.broadcastSnapshot(...)
                │
                ▼
        GUI AppState.apply(snapshot) → SwiftUI rerender
```

### Configuration flow

```
[User edits threshold in Settings]
        │
        ▼
SettingsView writes config.json in
~/Library/Group Containers/group.com.aarnavk.autowifi/config.json
        │
        ▼  (kernel: vnode change)
ConfigStore.fileWatcher fires
        │
        ▼
ConfigStore.reload() → publishes new Config via AsyncStream
        │
        ▼
CoordinatorActor.onConfig(newConfig) → updates dwell timers, thresholds, weights
```

---

## Suggested Build Order (this is the critical roadmap signal)

The components have a natural dependency order that produces an always-working, demonstrable artifact at each step. **Each step below is a candidate phase boundary.**

### Step 1 — CoreWLAN read-only inspector (CLI-shaped, no GUI yet)
Build a tiny standalone Swift command-line tool (or a one-window SwiftUI app) that:
- Asks for Location permission once.
- Calls `CWInterface.scanForNetworks` and `cachedScanResults`.
- Prints current SSID, BSSID, RSSI, channel, transmit rate.
- Subscribes to `scanCacheUpdated` events and re-prints on change.

**Why first:** validates entitlements + permissions + CW availability before any architecture is built. De-risks the entire project. **Cannot proceed without this working.**

### Step 2 — Health probes
Add `NWPathMonitor` + ping + DNS probe modules. Print live latency to current gateway, DNS success/failure. Still a single-process tool.

**Why second:** the second half of "what data do we have?" — and entirely independent of CoreWLAN, so the two can be built in parallel by one developer.

### Step 3 — Pure scoring + hysteresis engine, fully unit-tested
Implement `Shared/Algorithms/` (EMA, ScoringEngine, Hysteresis) with **synthetic inputs only**. Write the test suite first — replay sequences of scan/health samples and assert decision outputs.

**Why third:** the most subtle code in the project deserves to exist *before* it is wired to the radio. Bugs here are the entire failure mode of the product.

### Step 4 — State machine + decision actor wired to live data (still single process)
Connect Steps 1+2+3. Run the loop; **log decisions** to stdout/OSLog but do **not actually switch** yet. Verify decisions look sensible against the user's real WiFi environment for a day or two.

**Why fourth:** observe-only mode is the highest-value debugging phase. The decision log is born here.

### Step 5 — Switching action (still single process, dangerous-feeling)
Implement `SwitchActor.associate`. Keep auto-switching **off by default**; expose a "switch to network X now" CLI command. Test manually.

**Why fifth:** isolates the one truly destructive operation (changing the active network) from the decision logic that precedes it.

### Step 6 — GUI shell (window only, single process, talking directly to actors)
Stand up the SwiftUI app: MenuBarExtra + main window + settings. State comes from the in-process actors directly (no XPC yet). This gives a visually demoable product before the IPC engineering.

**Why sixth:** UI is iterative and shouldn't block on infrastructure. Defer the agent-split until the UI's needs are known — XPC protocols are easier to design after you've used a `@Bindable` mental model.

### Step 7 — Split agent + GUI processes; introduce XPC
Extract the actors into the agent target. Define `AgentProtocol`/`GUIObserverProtocol`. Re-wire the GUI to talk through XPC. Ship `SMAppService` registration.

**Why seventh:** the largest single piece of work; **this is the right phase boundary**, not earlier. By now the protocols are clear because real GUI consumption has shaped them.

### Step 8 — Persistence (SwiftData decision log + per-network prefs)
Add `PersistenceActor`, wire decisions to the store, build the decision-log view in the GUI. Add the Settings UI for per-network priority/blocklist.

**Why eighth:** the schema is now obvious because Steps 4–7 produced real `Decision` objects to persist.

### Step 9 — Polish + packaging
- Codesign + notarize the bundle.
- Auto-update hook (Sparkle, or a simple version-check link).
- Crash reporting (just OSLog for v1).
- Homebrew Cask manifest.

**Why last:** distribution work is concrete, well-trodden, and gates only the *release*, not the iteration.

---

### Why this build order matters for the roadmap

Steps 1–5 are all **single-process work**, which means there is no XPC complexity, no SMAppService friction, no Login Items prompt — and the developer learns CoreWLAN, the Network framework, the radio's quirks, and the hysteresis math before paying any process-split tax. Step 6 produces something demoable; Step 7 is when the architecture actually arrives. A roadmap that front-loads the IPC/SMAppService work (a tempting but wrong instinct: "infra first") will burn time on plumbing while still uncertain about the algorithm.

**Natural phase candidates** that emerge:
- **Phase A:** Read-only inspection (Steps 1–2) — validates the platform.
- **Phase B:** Decision engine (Steps 3–4) — produces the signature algorithm with tests.
- **Phase C:** Active switching (Step 5) — first dangerous operation, gated by user toggle.
- **Phase D:** GUI MVP (Step 6) — first portfolio-shaped artifact.
- **Phase E:** Background agent (Step 7) — production architecture.
- **Phase F:** History + tuning (Step 8) — decision log feature.
- **Phase G:** Distribution (Step 9) — sign, notarize, Brew.

---

## Scaling Considerations

This is a single-user, single-machine app. "Scale" here means **runtime efficiency**, not user growth.

| Metric | Target | What to watch |
|---|---|---|
| Idle CPU (STEADY state) | < 0.5% on M-series | Active scan cadence not too aggressive; CWEventDelegate doing most of the work. |
| Memory footprint | < 80 MB resident | SwiftData store growth (rotate decision log after N=10,000 entries). |
| Battery impact | imperceptible on laptop | Active scans dominate — keep STEADY cadence ≥ 60s. |
| Switching latency (decision → associated) | < 8 s typical | Mostly dominated by `CWInterface.associate` + DHCP. |
| Decision log query latency | < 50 ms for 1000-row paged window | SwiftData with proper `#Index` on `timestamp`. |

### What breaks first
1. **Active scan power cost** if cadence is set too aggressive — solved by the adaptive scheduler.
2. **CoreWLAN throttling** if the agent ignores the 10s minimum gap — solved by `ScanActor` guard.
3. **SwiftData store unbounded growth** — add a rolling-window deletion of decisions older than 90 days (or N entries).

---

## Anti-Patterns

### Anti-Pattern 1: Putting the monitoring loop on a GCD timer in the GUI app

**What people do:** Use `Timer.scheduledTimer` in the main app to call CoreWLAN every N seconds.

**Why it's wrong:** App suspends when the window closes (App Nap, especially on battery). LSUIElement helps but doesn't fully solve. CoreWLAN calls from the main actor block the UI. No way to run when the user logs in but doesn't open the app.

**Do this instead:** Background agent (SMAppService LaunchAgent), actors not timers, GUI is purely a view layer.

### Anti-Pattern 2: Sharing the `CWWiFiClient` singleton across queues

**What people do:** Call `CWWiFiClient.shared()` from multiple threads/queues.

**Why it's wrong:** CoreWLAN is not thread-safe. Crashes manifest later under load.

**Do this instead:** A single `ScanActor` owns the client. All callers `await` into it.

### Anti-Pattern 3: Building hysteresis with one big `if/else` ladder

**What people do:** Inline RSSI/health/dwell checks throughout the scan loop.

**Why it's wrong:** Untestable. Untunable. Every threshold change requires re-reading the loop body.

**Do this instead:** Three layered concerns — EMA smoothing, threshold bands, dwell timers — each a small testable type. Compose them in the `DecisionActor`.

### Anti-Pattern 4: Persisting transient state to SwiftData

**What people do:** Write every scan sample to disk.

**Why it's wrong:** Tens of thousands of writes per day, no useful query shape, store bloat.

**Do this instead:** Persist only **decisions** and **per-network rolling summaries**. Keep raw samples in memory in the relevant actor with a bounded ring buffer for the GUI's "live" view.

### Anti-Pattern 5: Letting the GUI hold the auto-switch on/off state

**What people do:** Boolean flag in the GUI's `@AppStorage`, passed to the agent on each scan.

**Why it's wrong:** Agent should be authoritative; GUI may be closed; you'll end up with two sources of truth that drift.

**Do this instead:** State lives in the agent (and on disk in `config.json`). GUI requests change via XPC; agent confirms via snapshot push. Single source of truth.

### Anti-Pattern 6: Distributed Notifications for live state

**What people do:** `DistributedNotificationCenter` broadcasts of scan results so multiple processes can listen.

**Why it's wrong:** No backpressure, no delivery guarantees, untyped dict payloads, harder to debug. Fine for occasional events; bad for a high-frequency status stream.

**Do this instead:** NSXPCConnection with a remote-proxy observer protocol.

---

## Integration Points

### External (system) services

| Service | Integration | Notes |
|---|---|---|
| CoreWLAN | `CWWiFiClient` + `CWInterface` + `CWEventDelegate` | Requires Location Services authorization on macOS 11+. Not thread-safe. Rate-limited (~10s between active scans). |
| Network framework | `NWPathMonitor`, `NWConnection` (UDP/TCP) | For reachability and ping-like probes. No special entitlements. |
| Keychain (system WiFi creds) | Implicit via `CWInterface.associate(toNetwork:password:error:)` with `password: nil` | macOS uses the System keychain entry for the SSID. Don't try to read or write WiFi passwords from the app. |
| ServiceManagement | `SMAppService.agent(plistName:)` | Requires macOS 13+. App must be signed (notarized for distribution outside the App Store). |
| launchd | via SMAppService + MachServices | Manages agent lifetime; provides the Mach port for XPC. |
| locationd | implicit consumer of CoreWLAN events | Heavy active scanning can starve locationd or vice versa — keep cadence reasonable. |
| OSLog | `Logger` per subsystem | "com.aarnavk.autowifi.{scan,health,decision,switch,xpc}" categories. |

### Internal boundaries

| Boundary | Communication | Notes |
|---|---|---|
| GUI ↔ Agent | NSXPCConnection over MachServices endpoint `com.aarnavk.autowifi.agent` | Request/reply + observer proxy push. |
| GUI ↔ Settings persistence | App Group container, `config.json` | Direct file write from GUI. |
| Agent ↔ config file | `DispatchSource.makeFileSystemObjectSource` + `JSONDecoder` | Live reload, no agent restart. |
| Agent ↔ SwiftData | `ModelActor` (PersistenceActor) | All store I/O goes through it. |
| CoordinatorActor ↔ everything | `AsyncStream<CoordinatorEvent>` | The one fan-in point. |
| Algorithms ↔ Actors | pure functions over Codable values | Algorithms layer has zero framework imports. |

---

## Open Questions / Items to Confirm in Phase 1 (Step 1 above)

These are worth surfacing for the roadmap because they shape later phases:

1. **Exact CoreWLAN scan rate limiting on macOS 14/15.** Community lore cites ~10s; Apple does not document it. Confirm empirically.
2. **Whether `CWInterface.associate(toNetwork:password:)` with `password: nil` reliably uses System Keychain creds for all SSID types (WPA2/WPA3/Enterprise).** WPA2 personal is well-attested; Enterprise may need different handling.
3. **Whether `scanCacheUpdated` events fire reliably on Sonoma+ when the GUI is not the frontmost app.** Some reports of locationd backing off.
4. **Whether SMAppService LaunchAgent registration in macOS 14.4+ requires any additional Info.plist keys beyond LSUIElement.** Apple dev forums show occasional error-125 reports; check current state.
5. **Whether ICMP ping requires raw socket entitlements or `NWConnection` UDP-to-gateway is sufficient.** Latter is much simpler if it works.

None of these block the recommended architecture; all are read-only verification tasks for Phase A.

---

## Sources

### Apple developer documentation
- [CWWiFiClient — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cwwificlient)
- [CWInterface scanForNetworks(withSSID:) — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cwinterface/scanfornetworks(withssid:))
- [CWEventDelegate — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cweventdelegate)
- [scanCacheUpdatedForWiFiInterface(withName:) — Apple Developer Documentation](https://developer.apple.com/documentation/corewlan/cweventdelegate/1512322-scancacheupdatedforwifiinterface)
- [MenuBarExtra — Apple Developer Documentation](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
- [Configuring App Groups — Apple Developer Documentation](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Accessing app group containers in your existing macOS app — Apple Developer Documentation](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
- [Wi-Fi roaming support in Apple devices — Apple Support](https://support.apple.com/guide/deployment/wi-fi-roaming-support-dep98f116c0f/web)

### Apple Developer Forums
- [SMAppService: registerAndReturnError behavior changes](https://forums.developer.apple.com/forums/thread/747573)
- [SMAppService: How to recover from errors](https://developer.apple.com/forums/thread/707482)
- [Privileged daemon using SMAppService in macOS Sequoia](https://forums.developer.apple.com/forums/thread/756846)
- [Sharing NSUserDefaults between XPC connections](https://developer.apple.com/forums/thread/701710)
- [macOS Sequoia: Shared UserDefaults reliability](https://developer.apple.com/forums/thread/774979)
- [Failed to perform Wi-Fi scan](https://developer.apple.com/forums/thread/761487)

### Architecture / IPC references
- [Inter-Process Communication — NSHipster](https://nshipster.com/inter-process-communication/)
- [XPC — objc.io](https://www.objc.io/issues/14-mac/xpc/)
- [XPC Services on macOS apps using Swift — RDerik](https://rderik.com/blog/xpc-services-on-macos-apps-using-swift/)
- [Technical Guide: Building a Modern Launch Agent on macOS — GitHub gist](https://gist.github.com/Matejkob/f8b1f6a7606f30777552372bab36c338)
- [macOS Service Management — The SMAppService API — theevilbit blog](https://theevilbit.github.io/posts/smappservice/)
- [macOS Apps With Embedded Daemons — DEV Community](https://dev.to/brysontyrrell/macos-apps-with-embedded-daemons-333a)

### Swift concurrency / Combine vs AsyncSequence
- [Observation in the World of Combine and Swift Async — Jack Morris](https://jackmorris.xyz/posts/2023/10/30/observation-in-the-world-of-combine-and-swift-async/)
- [Swift Observations AsyncSequence for State Changes — Use Your Loaf](https://useyourloaf.com/blog/swift-observations-asyncsequence-for-state-changes/)
- [SwiftData Background Tasks — Use Your Loaf](https://useyourloaf.com/blog/swiftdata-background-tasks/)
- [Core Data vs SwiftData: Which Should You Use — distantjob](https://distantjob.com/blog/core-data-vs-swiftdata/)

### Wi-Fi roaming algorithm references
- [macOS Wi-Fi Roaming — Frame by Frame](https://framebyframewifi.net/2017/08/20/macos-wi-fi-roaming/)
- [Mysteries of Wi-Fi Roaming Revealed — 7SIGNAL whitepaper](https://cdn2.hubspot.net/hubfs/353374/Knowledge%20Base/MYSTERIES%20of%20Wi-Fi%20Roaming%20Revealed%20-%207SIGNAL%20Whitepaper.pdf)
- [What Is WiFi Scan Throttling? — RottenWifi](https://blog.rottenwifi.com/wifi-scan-throttling/)

### Network framework
- [How to check for internet connectivity using NWPathMonitor — Hacking with Swift](https://www.hackingwithswift.com/example-code/networking/how-to-check-for-internet-connectivity-using-nwpathmonitor)
- [Measure pings to any host using Network Framework: iOS Swift](https://medium.com/@onlyapps/measure-pings-to-any-host-using-network-framework-ios-swift-3092ef367cd6)

### MenuBar / SwiftUI app patterns
- [Build a macOS menu bar utility in SwiftUI — nilcoalescing](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)
- [Showing Settings from macOS Menu Bar Items: A 5-Hour Journey — Peter Steinberger](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- [Itsycal — sfsam/Itsycal on GitHub](https://github.com/sfsam/Itsycal) (MIT-licensed reference for menubar/agent patterns)

### Practical CoreWLAN usage
- [macOS Wifi Scanning — clburlison](https://clburlison.com/macos-wifi-scanning/)
- [chbrown/macos-wifi — GitHub](https://github.com/chbrown/macos-wifi)
- [pavel-a/CoreWLANWirelessManager2 — modernized Apple sample](https://github.com/pavel-a/CoreWLANWirelessManager2)

---
*Architecture research for: native macOS WiFi auto-switching menubar agent*
*Researched: 2026-05-12*
