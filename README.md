# auto-wifi

A native macOS app that intelligently auto-switches between known Wi-Fi networks using **signal strength + measured throughput with hysteresis**, and explains every decision it makes in a transparent log.

**Status:** Phase 1 of 8 (Foundations). The current build is a read-only inspector that asks for Location Services authorization and shows your current connection plus every nearby known network. Active switching, the scoring engine, and the menubar surface ship in later phases.

## Why this exists

macOS's built-in Wi-Fi auto-join sticks with weak or dead networks and is slow to fall back to a stronger known one. There's no user-visible reason for any decision it makes. `auto-wifi` is designed to:

1. **Pick the genuinely best known network** in range — not just the one with the highest signal, but the one with the best measured health (latency + DNS reachability + packet loss).
2. **Never flap** between two near-equal networks — multi-layer hysteresis (EMA smoothing, threshold bands, dwell timers, post-switch cooldown) prevents oscillation.
3. **Explain every switch** — the decision log records why every transition happened, *and* why every rejected switch was rejected. This is the centerpiece, both as a debugging tool and as the portfolio storytelling artifact.

The full design is documented in `.planning/`:
- [`PROJECT.md`](.planning/PROJECT.md) — vision, constraints, key decisions
- [`REQUIREMENTS.md`](.planning/REQUIREMENTS.md) — 39 v1 requirements
- [`ROADMAP.md`](.planning/ROADMAP.md) — 8 build phases
- [`research/SUMMARY.md`](.planning/research/SUMMARY.md) — stack, features, architecture, and pitfalls research

## Phase 1 scope

This build delivers the five Foundations requirements (FOUND-01 through FOUND-05):

- Launches as a proper signed `.app` bundle
- Requests Location Services authorization with an in-app explanation of *why* macOS requires it for Wi-Fi metadata
- Shows a remediation banner with a one-click deep-link to System Settings if Location is denied or revoked
- Reads the system's saved Wi-Fi networks via `CWConfiguration.networkProfiles` and intersects them against a live scan, so you see exactly which of your known networks are currently in range and their RSSI / band / channel
- Built with Swift 6.2 + SwiftUI + CoreWLAN + CoreLocation — no deprecated APIs (no `airport`, no `SMJobBless`, no `SCNetworkReachability`)

Phase 2+ layer continuous health probes, the hysteresis scoring engine, the live decision loop, active switching, the menubar interface, background persistence, and the notarized distribution flow on top.

## Requirements

- macOS 14 (Sonoma) or newer — your current Mac (`sw_vers`) must be 14.0+
- Swift 6.0+ (Command Line Tools or full Xcode both work for `make app`)
- Full **Xcode** is only required for `make release` (notarization needs `xcrun notarytool`)

## Build

The everyday loop is `make app` + `make run`:

```sh
make app    # build dist/auto-wifi.app
make run    # build and open the app
```

`make app` runs `swift build` and then `Scripts/make-app.sh`, which assembles the SwiftPM-built binary into a proper `Contents/MacOS/AutoWiFi` bundle with `Info.plist` (containing the required `NSLocation*UsageDescription` keys) and entitlements, ad-hoc codesigned with the hardened runtime so Location Services authorization works.

> **Why this is hand-built and not an `.xcodeproj`.** macOS Location Services requires a real `.app` bundle with a stable bundle identifier — a bare `swift run` executable cannot get authorization. Until Xcode is installed, this Makefile + script approach produces a launchable bundle. When you install Xcode you can either keep this layout or generate an `.xcodeproj` via `xcodegen`.

## Release pipeline

The full notarized release flow is wired into the Makefile but requires:

- A **Developer ID Application** signing identity in your login keychain (`security find-identity -v -p codesigning`)
- A **notarytool keychain profile** stored once with:
  ```sh
  xcrun notarytool store-credentials AutoWiFiNotarization \
    --apple-id YOUR_APPLE_ID \
    --team-id YOUR_TEAM_ID \
    --password "app-specific-password"
  ```

Then:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Aarnav Koushik (TEAMID)" \
  make release
```

This runs `app-release` → `sign` → `notarize` → `dmg` and produces `dist/auto-wifi.dmg` ready to drag-install on any Mac.

## Layout

```
auto-wifi/
├── Package.swift                 # SwiftPM manifest, macOS 14+, Swift 6
├── Makefile                      # build / app / run / sign / notarize / release / dmg
├── README.md                     # ← you are here
├── Resources/
│   ├── Info.plist                # bundle metadata + NSLocation*UsageDescription
│   └── AutoWiFi.entitlements     # hardened-runtime entitlements
├── Scripts/
│   ├── make-app.sh               # wrap SwiftPM binary in .app
│   ├── sign.sh                   # Developer ID resign
│   ├── notarize.sh               # notarytool submit + stapler
│   └── make-dmg.sh               # hdiutil DMG
├── Sources/
│   ├── AutoWiFi/                 # @main SwiftUI app, views, controllers
│   ├── Algorithms/               # pure-logic scoring + hysteresis (populated in Phase 3)
│   └── Core/                     # shared models — WiFiBand, KnownNetwork, ScanResult, Candidate
└── .planning/                    # planning artifacts (PROJECT.md, REQUIREMENTS.md, ROADMAP.md, research/)
```

## Next phase

Phase 2 — Scanning + Health Probes + BSSID Data Model. The first step there is an empirical CoreWLAN spike on macOS 14.4+ to nail down four open questions (scan rate-limits, `associate(...)` with `nil` for Enterprise SSIDs, `scanCacheUpdated` reliability when the app is not frontmost, SMAppService Info.plist requirements) — see `.planning/STATE.md` "Blockers/Concerns".

---

© 2026 Aarnav Koushik
