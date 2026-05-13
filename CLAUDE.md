<!-- GSD:project-start source:PROJECT.md -->
## Project

**auto-wifi**

A macOS GUI app that intelligently manages connections to known WiFi networks. Continuously measures signal strength and real throughput across nearby known networks, and switches to the best-performing one — with hysteresis to prevent flapping between networks of similar quality. Built for personal use and as a portfolio piece.

**Core Value:** When multiple known WiFi networks are in range, the user is always on the genuinely best one — and never stranded on a dead or weak network because macOS was slow to switch.

### Constraints

- **Tech stack**: Swift + SwiftUI for the GUI — Why: native macOS look, portfolio-worthy modern stack, full access to system frameworks.
- **WiFi APIs**: CoreWLAN (CWInterface, CWWiFiClient) for scanning and association — Why: only sanctioned macOS API for this, and `networksetup` is too coarse for live RSSI/scan results.
- **Network health**: Apple's Network framework + lightweight in-app probes (ping, DNS lookup) — Why: avoids third-party speed-test dependencies and keeps the app self-contained.
- **Privileges**: CoreWLAN requires either Location Services permission (modern macOS) or an admin entitlement for some actions — Why: macOS gates SSID/BSSID visibility behind Location authorization since macOS 11.
- **Distribution**: Signed/notarized .app, optionally Homebrew Cask — Why: portfolio piece, not App Store, so signing+notarization is enough.
- **Platform**: macOS only, target macOS 14+ (Sonoma) — Why: modern SwiftUI features and current CoreWLAN behavior; no need to support legacy.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## TL;DR
## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Swift** | 6.2 (ships with Xcode 26.2) | App language | Swift 6 strict-concurrency catches data races at compile time — important for a continuously-running background agent doing concurrent scans/probes/UI updates. `@MainActor`, `Sendable`, and actors give us clean isolation between the scanning loop and the SwiftUI store. |
| **SwiftUI** | macOS 14 SDK | UI for main window + menubar | `MenuBarExtra` (added in macOS 13) is the SwiftUI-native way to build menubar apps with no AppKit. SwiftUI on macOS 14+ has matured enough (`Observable`, `Scene` improvements, table improvements) that you do not need AppKit shims for this app. |
| **Xcode** | 26.x (26.2+ recommended) | IDE, build, sign, archive | Required for entitlements UI, signing/provisioning, Asset Catalogs, and the archive→notarize flow. Xcode 26 ships Swift 6.2 and the macOS 26 SDK. You can deploy back to macOS 14. |
| **CoreWLAN** | macOS 14+ APIs | Wi-Fi scanning, RSSI, current interface state, association | The *only* sanctioned macOS API for live scan results and per-network RSSI. `CWWiFiClient.shared()` is the entry point; `CWInterface` exposes `scanForNetworks(withSSID:)`, `interfaceName`, `rssiValue()`, `ssid()`, `bssid()`, `disassociate()`. |
| **CoreLocation** | macOS 14+ | Unlock SSID/BSSID values | **Mandatory since macOS 11, strictly enforced from macOS 14.4+**: `CWInterface.ssid()` / `.bssid()` and scan-result SSID/BSSID return `nil` unless the app has *authorized* Location Services. You must instantiate `CLLocationManager`, set delegate, call `requestAlwaysAuthorization()` (or `requestWhenInUseAuthorization()`), and wait for `.authorizedAlways`/`.authorizedWhenInUse` before relying on SSID data. |
| **Network framework** | macOS 14+ | Health probes (reachability, DNS, latency) | Modern Apple-blessed replacement for `SCNetworkReachability`. Use `NWPathMonitor` for "do we have a usable path?" events, and short-lived `NWConnection` (UDP to gateway for latency, or TCP+TLS to a known host) for active probes. No third-party dependency. |
| **Service Management** | macOS 13+ (`SMAppService`) | Register background LaunchAgent | `SMAppService.agent(plistName:)` is the modern replacement for `SMLoginItemSetEnabled` (deprecated) and bare `launchctl load`. User-visible in System Settings → General → Login Items. Bundled `.plist` lives in `Contents/Library/LaunchAgents/` inside the .app. |
| **OSLog / Logger** | macOS 14+ | Structured logging for the decision log | `Logger` (the Swift wrapper over `os_log`) is the standard. Decision-log entries are both shown in-app and archived to the unified log so they survive crashes and can be retrieved with `log show`. |
### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| **swift-async-algorithms** | 1.0.x | `AsyncTimerSequence`, `debounce`, `throttle`, `combineLatest` for async streams | The hysteresis logic naturally fits as: scan-results stream + health-probe stream → debounced → decision. Apple's package, no risk. |
| **swift-collections** | 1.x | `OrderedDictionary`, `Deque` for the decision log ring buffer | Only if you need the data structures; otherwise skip. Apple's package. |
| **swift-log** | *Avoid* | — | Don't — use `Logger`/`os.log` directly. `swift-log` is for server-side Swift. |
| **Sparkle** | 2.6+ | App auto-update | *Only* if you ship outside Homebrew Cask. If Homebrew is the primary channel, Cask handles updates. Defer until v2. |
| **MenuBarExtraAccess** | 1.x | Programmatic show/hide of `MenuBarExtra` window | Optional — pure SwiftUI `MenuBarExtra` cannot be opened/closed from code. Add only if a feature actually needs it. |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| **`xcodebuild`** | CI/CLI builds, archive | Drive archive + export from a script: `xcodebuild -scheme AutoWiFi -configuration Release archive` then `xcodebuild -exportArchive`. |
| **`xcrun notarytool`** | Notarization submission | **Mandatory.** `altool` was decommissioned Nov 1 2023 and the notary service no longer accepts its uploads. Use App Store Connect API key (stored in `xcrun notarytool store-credentials`). |
| **`xcrun stapler`** | Staple notarization ticket to `.app` and `.dmg` | Required so Gatekeeper works offline. |
| **`codesign`** | Sign the app and embedded helpers | Use `--options runtime` (hardened runtime — required for notarization), `--timestamp`, and a Developer ID Application certificate. |
| **`create-dmg`** (Homebrew) | Build a polished DMG | `brew install create-dmg`. Standard for non-App-Store distribution. Sign the DMG *after* creation, then notarize+staple. |
| **SwiftFormat** | Code style | Optional but recommended for portfolio polish. Run as Xcode build phase or pre-commit hook. |
| **SwiftLint** | Lint | Optional. Choose one of SwiftLint/SwiftFormat to avoid conflict, or run lint-only mode of SwiftFormat. |
| **GitHub Actions** | CI for build + test | macOS-15 runners can build, sign requires storing the cert+API key as secrets. |
## Critical: Location Services Authorization Implications
### What triggers the authorization requirement
| API | Behavior without authorization (macOS 14.4+) |
|-----|----------------------------------------------|
| `CWInterface.ssid()` | Returns `nil` |
| `CWInterface.bssid()` | Returns `nil` |
| `CWNetwork.ssid` (from scan results) | Returns `nil` (the scan still returns network objects, but with hidden identifiers) |
| `CWNetwork.bssid` (from scan results) | Returns `nil` |
| `CWInterface.scanForNetworks(...)` | Call *succeeds* and returns RSSI/signal data, but SSIDs/BSSIDs are redacted |
| `CWInterface.rssiValue()` | Works — RSSI does **not** require auth |
| `CWInterface.interfaceName` | Works — interface name (e.g., `en0`) does not require auth |
### Required flow
### Bundled-app requirement
### LaunchAgent quirk
## Background-Agent Architecture: `SMAppService.agent(...)`
### Required setup
### Single-binary vs helper-binary
### macOS 13 minimum for `SMAppService`
## Distribution: Signing, Notarization, Homebrew Cask
### Signing pipeline (required before notarization)
### Notarization pipeline
# One-time credential storage
# Per-release
# Then create the DMG, sign it, submit the DMG, staple the DMG.
### DMG packaging
### Homebrew Cask
## Build Tooling: Xcode Project, Not Pure SwiftPM
- **Entitlements editor** — you need `com.apple.developer.networking.wifi-info`, `com.apple.security.network.client`, and (for hardened runtime) entitlements that disable JIT/library validation, etc. SwiftPM has no first-class entitlements UI.
- **Asset Catalog** — for the menubar icon set (template variants), Dock icon, and color assets.
- **`Info.plist`** is non-trivial: `LSUIElement`, location-usage strings, `SMAppService` references — Xcode's UI is much friendlier than hand-editing.
- **Archive + Notarize flow** is built into Xcode's Organizer.
- **Code signing** UI is in Xcode targets.
## Testing: Swift Testing for Logic, XCTest for UI
| Test type | Framework | Reason |
|-----------|-----------|--------|
| Unit tests (hysteresis logic, scan parsing, decision engine, probe scheduling) | **Swift Testing** (`import Testing`) | Apple's WWDC24 framework, ships with Xcode 16+. `@Test`, `#expect`, parameterized tests, parallel-by-default. The de facto 2026 default for Swift code. |
| UI tests (SwiftUI window, menubar interactions) | **XCTest** + `XCUIApplication` | Swift Testing does **not** support UI tests (still XCTest-only as of Xcode 26). |
| Performance tests (scan cadence, memory of long-running agent) | XCTest with `measure { }` | Swift Testing also does not yet support measurement APIs. |
## Installation
# Developer machine prerequisites
# Xcode 26.2+ from the App Store
# Build/distribution tooling
# notarytool, codesign, stapler ship with Xcode — no install needed
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| **Swift + SwiftUI** | Electron / Tauri | Never for this project — defeats the portfolio purpose and gives no access to CoreWLAN. |
| **Swift + SwiftUI** | AppKit (Storyboards/XIBs) | Only if a SwiftUI gap (e.g., highly-custom menubar interactions) becomes blocking. Use `NSViewRepresentable` for one-off escape hatches. |
| **CoreWLAN** | shelling out to `networksetup` / `airport -s` | Never — `airport -s` was **removed** in macOS 15 Sequoia, `networksetup -listallhardwareports` started deprecation in Sequoia. CoreWLAN is the only stable path. |
| **`NWConnection` for probes** | `swift-nio` | Never — `NWConnection` is sufficient; swift-nio is for server-side Swift. |
| **`SMAppService.agent`** | hand-installed LaunchAgent (`launchctl load` of a user-installed plist) | Never on macOS 13+ — Background Task Management (BTM) will warn the user about "background items" and the experience is worse than the system-supported path. |
| **`SMAppService.agent`** | `SMAppService.loginItem` | Only if you want the app to launch its GUI at login rather than run as a headless agent. The two can be combined (login item + on-demand agent). |
| **`xcrun notarytool`** | `altool` | **Never** — decommissioned Nov 2023. |
| **`xcrun notarytool`** | third-party services (fastlane match for notarization) | Only if you have an existing fastlane pipeline. Pure notarytool is simpler. |
| **Xcode project + SwiftPM libraries** | Pure SwiftPM executable target | Only for a CLI-only tool with no Info.plist, no entitlements, no asset catalog. Not this project. |
| **Swift Testing** | XCTest | UI tests, performance tests, or legacy team familiarity. |
| **Homebrew Cask** | Mac App Store | The user has explicitly excluded App Store. Cask is the lowest-friction modern alternative. |
| **Homebrew Cask** | Direct DMG download from a website | Always do this too — Cask just adds discoverability. |
| **CoreLocation auth** | `com.apple.developer.networking.wifi-info` entitlement | The `wifi-info` entitlement is **iOS-only** (Hotspot Helper / NEHotspot). On macOS, Location Services authorization is the gate. Do not request `wifi-info` for a macOS app — it will not help. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| **`altool`** | Apple decommissioned uploads Nov 1 2023. The notary service rejects them. | `xcrun notarytool` |
| **`SMLoginItemSetEnabled`** | Deprecated in macOS 13. User-hostile (no System Settings visibility). | `SMAppService.loginItem` or `SMAppService.agent` |
| **`SMJobBless`** | Deprecated in macOS 13. Was for privileged helpers; this app does not need root. | `SMAppService.daemon` only if you genuinely need a root daemon (you don't). |
| **`SCNetworkReachability`** | Long-deprecated by Apple in favor of Network framework. Boolean answer is too coarse for our health-check use. | `NWPathMonitor` for path events; `NWConnection` for active probes. |
| **`airport` CLI (`/System/Library/.../airport`)** | **Removed in macOS 15 Sequoia.** Worked for years; gone now. | `CWWiFiClient` / `CWInterface` APIs directly. |
| **`networksetup -listallhardwareports`** | Began deprecation in Sequoia; Apple explicitly directs developers to CoreWLAN. | `CWWiFiClient.shared().interfaces()` |
| **`com.apple.developer.networking.wifi-info` entitlement on macOS** | iOS-only. Does nothing on macOS. The macOS gate is CoreLocation authorization. | `CLLocationManager.requestAlwaysAuthorization()` |
| **Pure SwiftPM executable for the app** | No Info.plist UX, no entitlements UX, no Archive flow, harder notarization. | Xcode project with local SwiftPM library targets for modularization. |
| **`SCNetworkConfiguration` for joining networks** | Lower-level than needed; `CWInterface.associate(...)` is the supported path. | `CWInterface.associate(to: CWNetwork, password: String?)` — note: passing `nil` to join a saved network is unreliable (see Pitfalls). |
| **`@StateObject` / `ObservableObject` for new code** | Replaced by `@Observable` macro in iOS 17/macOS 14. | `@Observable` macro with `@State` / `@Bindable`. |
| **`Combine` for new code** | Apple is steering toward `AsyncSequence` / `AsyncStream`. Combine still works but feels legacy. | `AsyncStream` + `swift-async-algorithms` for the scan→probe→decision pipeline. |
| **swift-log** | Server-side library; clashes with `Logger`/`os_log` on Apple platforms. | Foundation `Logger` (the Swift wrapper for `os_log`). |
| **Sparkle (v1.x)** | Old EdDSA-less releases not Gatekeeper-friendly. | Sparkle 2.x with EdDSA signing — but **defer Sparkle entirely** if Homebrew Cask is the channel; Cask updates the app. |
## Stack Patterns by Variant
- Build is the same, but distribution becomes "users must right-click → Open" on first launch and Homebrew Cask is unavailable (Homebrew rejects unsigned casks from Sept 2026). Not recommended for a portfolio piece — pay the $99.
- Still works. `SMAppService`, `MenuBarExtra`, and `@Observable` all exist on 13. Drop CoreLocation to `requestWhenInUseAuthorization()` (Always works on 13 too). Lose only minor 14-specific SwiftUI niceties.
- Don't. iOS Wi-Fi APIs are crippled — `NEHotspotHelper` requires special Apple entitlement granted only to Wi-Fi vendors. Cross-platform is explicitly out of scope for this project, and CoreWLAN does not exist on iOS.
- Possible v1.0 strategy: make the app itself a `LSUIElement = true` agent app (no Dock icon) and ask the user to add it to Login Items via `SMAppService.loginItem`. Then the "main window" is just a window the user opens from the menubar. Simpler than a separate LaunchAgent. **Recommended starting point** — promote to LaunchAgent only if there's a reason the main app cannot stay running (e.g., GUI process restarting frequently).
## Version Compatibility
| Component | Minimum | Why this minimum |
|-----------|---------|------------------|
| macOS deployment target | **14.0 Sonoma** | `@Observable` macro, `Scene`-based MenuBarExtra refinements, `NavigationStack` mature, current CoreWLAN/CoreLocation enforcement model. The PROJECT.md already commits to 14+. |
| Xcode | **26.0** (26.2 preferred) | Swift 6 strict concurrency available, latest SDKs, current notarytool. |
| Swift toolchain | **6.0+** (6.2 ships with Xcode 26.2) | Strict concurrency mode for background-loop safety. |
| `SMAppService` | macOS 13+ | We're on 14, so no concern. |
| `MenuBarExtra` | macOS 13+ | We're on 14, so no concern. |
| `@Observable` | macOS 14+ | Aligned with our target. |
| `xcrun notarytool` | Xcode 13+ | Universally available. |
| Homebrew 5.x (signing enforcement) | — | Already enforced for new submissions; full removal of unsigned casks by Sept 2026. Our pipeline meets this. |
## Sources
### Apple Developer Documentation (HIGH confidence)
- [CoreWLAN framework](https://developer.apple.com/documentation/corewlan) — CWWiFiClient, CWInterface, CWNetwork APIs
- [CWInterface](https://developer.apple.com/documentation/corewlan/cwinterface) — associate/disassociate, scan methods, RSSI access
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — modern LaunchAgent/Daemon/LoginItem registration (macOS 13+)
- [Network framework / NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) — modern reachability and path monitoring
- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) — altool decommission, notarytool migration
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — official notarization flow
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) — script-based notarization
- [MenuBarExtra (SwiftUI)](https://developer.apple.com/documentation/swiftui/menubarextra) — macOS 13+ menubar scene
- [Adopting strict concurrency in Swift 6](https://developer.apple.com/documentation/swift/adoptingswift6) — Swift 6 concurrency model
- [Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) — current Xcode/Swift tooling
- [Meet Swift Testing — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10179/) — Swift Testing introduction
- [Swift Testing — Apple Developer](https://developer.apple.com/xcode/swift-testing/) — overview page
- [Access Wi-Fi Information Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.wifi-info) — confirms iOS-only scope
### Apple Developer Forums (HIGH confidence — official Apple engineers)
- [CoreWLAN returning null SSID with macOS Sonoma](https://developer.apple.com/forums/thread/748518) — confirms Location Services requirement and bundle-id dependence
- [macOS get SSID changes?](https://developer.apple.com/forums/thread/732431) — confirms Sonoma 14.x behavioral change
- [MacOS - SSID attribute is Nil on Sonoma OS version](https://developer.apple.com/forums/thread/737455) — additional context on the auth flow
- [SMAppService: How to recover from errors](https://developer.apple.com/forums/thread/707482) — SMAppService usage patterns
- [Launching agent installed with SMAppService](https://developer.apple.com/forums/thread/750528) — agent lifecycle
### Community (MEDIUM confidence — used to corroborate Apple sources)
- [SMAppService Quick Notes — theevilbit blog](https://theevilbit.github.io/posts/smappservice/) — practical SMAppService walkthrough
- [Workbrew: What Homebrew 5.0.0 means for your Mac fleet](https://workbrew.com/blog/homebrew-5-0-0) — cask signing-enforcement timeline
- [Notarisation in macOS Sonoma — Homebrew Discussion #4582](https://github.com/orgs/Homebrew/discussions/4582) — practical Homebrew Cask requirements
- [Build a macOS menu bar utility in SwiftUI — nilcoalescing](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/) — MenuBarExtra reference pattern
- [Hands-on: building a Menu Bar experience with SwiftUI — Cindori](https://cindori.com/developer/hands-on-menu-bar) — MenuBarExtra with .window style
- [Collecting active SSID with macOS Sonoma 14.4 — Jamf community](https://community.jamf.com/general-discussions-2/collecting-active-ssid-with-macos-sonoma-14-4-and-later-32298) — fleet-management perspective on the Sonoma SSID gate
- [Swift Testing: The Complete Guide from Swift 6.0 to 6.2 — Atelier Socle](https://www.atelier-socle.com/en/articles/swift-testing-guide) — Swift Testing feature inventory
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
