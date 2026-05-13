import SwiftUI
import Core
import Algorithms

/// UI-05: Settings scene shows the read-only hysteresis thresholds and the per-network
/// preferences editor. v1 keeps thresholds read-only (TUNE-01 deferred); a small note in the
/// UI explains they're tunable in v2.
///
/// Per-network preferences live in AppState's `networkPreferences` map (Phase 6: in-memory;
/// Phase 7 will persist via SwiftData). The picker per network is the affordance for
/// UI-05's "prefer / avoid / never auto-join."
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            ThresholdsTab()
                .tabItem { Label("Algorithm", systemImage: "function") }
            NetworkPreferencesTab()
                .tabItem { Label("Networks", systemImage: "list.bullet") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct ThresholdsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let c = state.decisions.config
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hysteresis thresholds")
                    .font(.headline)
                Text("These constants are read-only in v1. Editable thresholds ship in a future version (TUNE-01).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 6)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
                    section("Smoothing")
                    row("EMA α", String(format: "%.2f", c.emaAlpha), help: "How fast the smoother reacts to fresh RSSI samples (0=ignore, 1=no memory).")

                    section("Threshold bands")
                    row("Good-enough RSSI", "\(c.goodEnoughRSSI) dBm", help: "Above this, the current connection is healthy; no switch is considered.")
                    row("Too-weak RSSI", "\(c.tooWeakRSSI) dBm", help: "Below this, the current connection is marked degraded; candidates are evaluated.")

                    section("Dwell timers")
                    row("Degrade dwell", "\(Int(c.degradeDwell)) s", help: "Sustained-weak window before considering candidates.")
                    row("Candidate dwell", "\(Int(c.candidateDwell)) s", help: "Candidate must stay best for this long before committing.")
                    row("Post-switch cooldown", "\(Int(c.postSwitchCooldown)) s", help: "Decisions are frozen for this long after switching.")

                    section("Switch margin")
                    row("Switch margin", String(format: "%.0f pts", c.switchMargin), help: "Candidate must score at least this much higher to switch.")
                    row("Active-traffic multiplier", String(format: "×%.1f", c.activeTrafficMarginMultiplier), help: "Margin is multiplied by this when the user is on a call/transfer.")

                    section("Score modifiers")
                    row("Prefer boost", "+\(Int(c.preferBoost))", help: "Added to networks the user marked as preferred.")
                    row("Avoid penalty", "\(Int(c.avoidPenalty))", help: "Subtracted from networks the user marked as avoid.")
                    row("Captive penalty", "\(Int(c.captivePenalty))", help: "Subtracted when the app detected a captive portal on the network.")
                    row("Never-auto-join", "\(Int(c.neverAutoJoinPenalty))", help: "Effectively disqualifies a network from auto-switch.")
                    row("5 GHz boost", "+\(Int(c.bandBoost5GHz))", help: "Small preference for 5 GHz over 2.4 GHz.")
                    row("6 GHz boost", "+\(Int(c.bandBoost6GHz))", help: "Slightly larger preference for 6 GHz where available.")
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section(_ title: String) -> some View {
        GridRow {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary).gridCellColumns(2).padding(.top, 6)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, help: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                Text(help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .gridColumnAlignment(.trailing)
        }
    }
}

private struct NetworkPreferencesTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Aggregate every SSID we've ever seen, plus any with an existing preference.
        let knownSSIDs: [String] = {
            var seen = Set<String>()
            for c in state.scan.snapshot.allInRange where c.isKnown {
                seen.insert(c.scan.ssid)
            }
            for ssid in state.networkPreferences.keys {
                seen.insert(ssid)
            }
            return seen.sorted()
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Per-network preferences")
                    .font(.headline)
                Spacer()
                if !state.networkPreferences.isEmpty {
                    Button("Clear all") { state.networkPreferences.removeAll() }
                        .controlSize(.small)
                }
            }
            Text("Bias the decision engine toward or away from specific known networks. Phase 7 will persist these across launches.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            if knownSSIDs.isEmpty {
                Spacer()
                Text("No known networks observed yet.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(knownSSIDs, id: \.self) { ssid in
                            NetworkPrefRow(ssid: ssid)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}

private struct NetworkPrefRow: View {
    @Environment(AppState.self) private var state
    let ssid: String

    var body: some View {
        HStack(spacing: 12) {
            Text(ssid)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { state.networkPreferences[ssid] ?? NetworkPreference.neutral },
                set: { state.setPreference($0, for: ssid) }
            )) {
                Text("Prefer").tag(NetworkPreference.prefer)
                Text("Neutral").tag(NetworkPreference.neutral)
                Text("Avoid").tag(NetworkPreference.avoid)
                Text("Never").tag(NetworkPreference.neverAutoJoin)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi.circle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)
            Text("auto-wifi")
                .font(.title2.weight(.semibold))
            Text("Phase 6 build · Algorithms \(Algorithms.version)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("A macOS GUI app that intelligently auto-switches between known Wi-Fi networks using signal + measured health with multi-layer hysteresis.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .foregroundStyle(.secondary)
            Spacer()
            Text("© 2026 Aarnav Koushik")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(20)
    }
}
