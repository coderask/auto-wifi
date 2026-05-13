# Stack Research

**Domain:** Native macOS GUI utility app — Wi-Fi management with background agent, signed/notarized distribution (non-App-Store)
**Researched:** 2026-05-12
**Confidence:** HIGH (verified against Apple developer documentation + current 2026 community reports; CoreWLAN association behavior flagged MEDIUM)

---

## TL;DR

Build with **Swift 6.2** + **SwiftUI** in an **Xcode 26 project** (not pure SwiftPM), targeting **macOS 14.0 Sonoma** as minimum. Use **CoreWLAN** for scanning and reading interface state, **CoreLocation** to unlock SSID/BSSID visibility (mandatory since macOS 14), **Network framework** (`NWPathMonitor` + `NWConnection`) for health probes, **`MenuBarExtra`** scene + a regular `WindowGroup` for the dual UI, and **`SMAppService.agent(plistName:)`** to register the LaunchAgent. Sign with a **Developer ID Application** cert, notarize with **`xcrun notarytool`**, package as **DMG via `create-dmg`**, and optionally publish a **Homebrew Cask** (which now *requires* signing+notarization as of Homebrew 5.x). Test with **Swift Testing** (default), reserving **XCTest** only for any UI tests.

---

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

The app should stay **dependency-light** — system frameworks cover all core needs. The only third-party additions worth considering:

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

---

## Critical: Location Services Authorization Implications

This is the single biggest UX issue for the app. Document carefully.

### What triggers the authorization requirement

These CoreWLAN APIs return `nil` / empty values when Location Services is **not** authorized for the app:

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

1. App launches.
2. Before the first scan, instantiate `CLLocationManager`, set its delegate, call `requestAlwaysAuthorization()` (you want `.always` so the background agent works when no window is open).
3. Add `NSLocationUsageDescription` (and `NSLocationAlwaysAndWhenInUseUsageDescription` on macOS) to `Info.plist` with a clear, honest string like *"AutoWiFi needs Location access to read Wi-Fi network names (SSIDs). It does not record or transmit your location."* — macOS shows this string verbatim in the permission prompt.
4. Wait for `locationManagerDidChangeAuthorization(_:)` to fire with `.authorizedAlways` before doing any SSID-dependent work.
5. **Also** call `startUpdatingLocation()` at least once after authorization — community reports show some Sonoma builds need the location-manager session to be "live" for SSIDs to resolve, even with authorization granted. You can immediately call `stopUpdatingLocation()`.
6. Handle `.denied` and `.restricted` gracefully — display a banner in the main window and a different menubar icon, and surface a "Open Privacy Settings" button (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`).

### Bundled-app requirement

`locationd` ties authorization to the app's **bundle identifier**. A bare command-line tool (no `.app` wrapper, no bundle ID, no `Info.plist`) cannot be granted Location auth reliably and will see redacted SSIDs even with the user trying to authorize. **You must ship a real `.app` bundle.** This is also a hard prerequisite for notarization.

### LaunchAgent quirk

Reports indicate that on macOS 14.x, a LaunchAgent process may *intermittently* see redacted SSIDs even though the parent `.app` is authorized. Mitigation: have the LaunchAgent re-confirm `CLLocationManager.authorizationStatus` on startup and call `startUpdatingLocation()` briefly before the first scan.

---

## Background-Agent Architecture: `SMAppService.agent(...)`

**Use this — not bare `launchctl`, not `SMLoginItemSetEnabled` (deprecated), not `SMJobBless` (deprecated).**

### Required setup

1. Add a `.plist` file (e.g., `com.aarnavkrishnan.autowifi.agent.plist`) to your Xcode target's `Contents/Library/LaunchAgents/` resources path.
2. The plist's `BundleProgram` key points at the helper binary (or at the main app's binary with a launch arg like `--agent`).
3. From the main app, register on first launch (or from a Settings toggle):
   ```swift
   let service = SMAppService.agent(plistName: "com.aarnavkrishnan.autowifi.agent.plist")
   try service.register()
   ```
4. The user gets a *one-time* approval prompt routed through System Settings → General → Login Items & Extensions. Until approved, `service.status` is `.requiresApproval`.
5. To unregister: `try service.unregister()`.

### Single-binary vs helper-binary

For an app of this complexity, **prefer single-binary** with a `--agent` launch arg. The main `.app` launches with the agent flag from launchd; the GUI is launched separately by the user clicking the app. Both share the same code and same bundle identifier, simplifying signing, entitlements, and Location authorization.

### macOS 13 minimum for `SMAppService`

`SMAppService` requires **macOS 13 Ventura**. Since we target macOS 14, this is fine. Do not fall back to `SMLoginItemSetEnabled`.

---

## Distribution: Signing, Notarization, Homebrew Cask

### Signing pipeline (required before notarization)

1. **Developer ID Application** cert (Apple Developer Program membership required — $99/yr).
2. Build with `xcodebuild archive` → `xcodebuild -exportArchive` using a "Developer ID" export options plist.
3. Hardened Runtime: enabled in Xcode target settings ("Hardened Runtime" capability) — required for notarization.
4. Embedded helpers (the LaunchAgent helper, if separate; any frameworks) must be signed with `--options runtime` and the same Team ID.

### Notarization pipeline

```bash
# One-time credential storage
xcrun notarytool store-credentials "AC_NOTARY" \
    --apple-id "you@example.com" \
    --team-id "ABCDE12345" \
    --password "<app-specific-password-or-API-key>"

# Per-release
xcrun notarytool submit AutoWiFi.zip --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple AutoWiFi.app
# Then create the DMG, sign it, submit the DMG, staple the DMG.
```

`altool` is **decommissioned** — do not use it. (Verified: Apple TN3147; notary service stopped accepting altool uploads Nov 2023.)

### DMG packaging

```bash
brew install create-dmg
create-dmg \
    --volname "AutoWiFi" \
    --window-size 600 400 \
    --icon-size 100 \
    --app-drop-link 450 200 \
    AutoWiFi.dmg AutoWiFi.app
codesign --sign "Developer ID Application: Your Name (TEAMID)" AutoWiFi.dmg
xcrun notarytool submit AutoWiFi.dmg --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple AutoWiFi.dmg
```

### Homebrew Cask

Homebrew 5.x (released March 2026) now **enforces** code-signing + notarization for casks; unsigned/unnotarized casks are scheduled for removal by **September 1, 2026**. Our signed+notarized build meets this requirement automatically.

A minimal Cask formula looks like:

```ruby
cask "auto-wifi" do
  version "0.1.0"
  sha256 "<sha256 of the DMG>"
  url "https://github.com/aarnavkkk/auto-wifi/releases/download/v#{version}/AutoWiFi-#{version}.dmg"
  name "AutoWiFi"
  desc "Intelligent Wi-Fi auto-switcher for macOS"
  homepage "https://github.com/aarnavkkk/auto-wifi"
  app "AutoWiFi.app"
  zap trash: [
    "~/Library/Application Support/AutoWiFi",
    "~/Library/Preferences/com.aarnavkrishnan.autowifi.plist",
    "~/Library/LaunchAgents/com.aarnavkrishnan.autowifi.agent.plist",
  ]
end
```

Submit to `homebrew/cask` or host your own tap at `homebrew-aarnavkkk/auto-wifi`. A personal tap is the easier path for a portfolio piece.

---

## Build Tooling: Xcode Project, Not Pure SwiftPM

**Use an Xcode project (`.xcodeproj`), not a pure `Package.swift` build.**

Reasons:
- **Entitlements editor** — you need `com.apple.developer.networking.wifi-info`, `com.apple.security.network.client`, and (for hardened runtime) entitlements that disable JIT/library validation, etc. SwiftPM has no first-class entitlements UI.
- **Asset Catalog** — for the menubar icon set (template variants), Dock icon, and color assets.
- **`Info.plist`** is non-trivial: `LSUIElement`, location-usage strings, `SMAppService` references — Xcode's UI is much friendlier than hand-editing.
- **Archive + Notarize flow** is built into Xcode's Organizer.
- **Code signing** UI is in Xcode targets.

**Where to use SwiftPM:** internal modularization. Split pure-logic modules (the hysteresis decision engine, the probe scheduler) into local Swift packages within the workspace. Test those packages with `swift test` from the CLI. The Xcode app target depends on the packages.

This hybrid pattern (Xcode app + local SwiftPM library targets) is the 2026 default for serious Mac apps.

---

## Testing: Swift Testing for Logic, XCTest for UI

| Test type | Framework | Reason |
|-----------|-----------|--------|
| Unit tests (hysteresis logic, scan parsing, decision engine, probe scheduling) | **Swift Testing** (`import Testing`) | Apple's WWDC24 framework, ships with Xcode 16+. `@Test`, `#expect`, parameterized tests, parallel-by-default. The de facto 2026 default for Swift code. |
| UI tests (SwiftUI window, menubar interactions) | **XCTest** + `XCUIApplication` | Swift Testing does **not** support UI tests (still XCTest-only as of Xcode 26). |
| Performance tests (scan cadence, memory of long-running agent) | XCTest with `measure { }` | Swift Testing also does not yet support measurement APIs. |

You can mix both in one test target — they coexist.

For the **decision engine** specifically (the core algorithmic value of the project), aim for very high coverage with Swift Testing parameterized tests modeling network scenarios.

---

## Installation

```bash
# Developer machine prerequisites
xcode-select --install
# Xcode 26.2+ from the App Store

# Build/distribution tooling
brew install create-dmg swiftformat swiftlint
# notarytool, codesign, stapler ship with Xcode — no install needed
```

```swift
// Package.swift (for internal modules used by the Xcode app)
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoWiFiCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DecisionEngine", targets: ["DecisionEngine"]),
        .library(name: "Probes", targets: ["Probes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DecisionEngine",
            dependencies: [
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .target(name: "Probes"),
        .testTarget(name: "DecisionEngineTests", dependencies: ["DecisionEngine"]),
        .testTarget(name: "ProbesTests", dependencies: ["Probes"]),
    ]
)
```

---

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

---

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

---

## Stack Patterns by Variant

**If you want zero Apple Developer Program cost (no $99/yr):**
- Build is the same, but distribution becomes "users must right-click → Open" on first launch and Homebrew Cask is unavailable (Homebrew rejects unsigned casks from Sept 2026). Not recommended for a portfolio piece — pay the $99.

**If you decide later to support macOS 13 Ventura:**
- Still works. `SMAppService`, `MenuBarExtra`, and `@Observable` all exist on 13. Drop CoreLocation to `requestWhenInUseAuthorization()` (Always works on 13 too). Lose only minor 14-specific SwiftUI niceties.

**If you decide later to add multi-platform (iPad, etc.):**
- Don't. iOS Wi-Fi APIs are crippled — `NEHotspotHelper` requires special Apple entitlement granted only to Wi-Fi vendors. Cross-platform is explicitly out of scope for this project, and CoreWLAN does not exist on iOS.

**If you want to skip the LaunchAgent entirely:**
- Possible v1.0 strategy: make the app itself a `LSUIElement = true` agent app (no Dock icon) and ask the user to add it to Login Items via `SMAppService.loginItem`. Then the "main window" is just a window the user opens from the menubar. Simpler than a separate LaunchAgent. **Recommended starting point** — promote to LaunchAgent only if there's a reason the main app cannot stay running (e.g., GUI process restarting frequently).

---

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

---

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

---

*Stack research for: native macOS GUI utility with background Wi-Fi management, signed+notarized non-App-Store distribution*
*Researched: 2026-05-12*
