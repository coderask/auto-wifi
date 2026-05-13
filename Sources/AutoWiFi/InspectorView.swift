import SwiftUI
import Core
import Algorithms

/// Main user-facing surface. Composes: header (mode toggle + scan cadence + refresh),
/// current connection, health, FSM banner, last-decision summary, known-in-range table,
/// full decision log, all-in-range disclosure. Phase 6 will split this into discrete
/// surfaces wired through MenuBarExtra; for now it lives in one window.
struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FSMBanner()
                    HoldBanner()
                    CurrentConnectionCard()
                    HealthCard()
                    LastDecisionCard()
                    KnownInRangeSection()
                    DecisionLogSection()
                    AllInRangeSection()
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HoldBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.guards.isHeld {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-switching suspended")
                        .font(.headline)
                    Text(state.guards.holdReason ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resume") { state.clearAllHolds() }
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 8) {
                Spacer()
                Text("Pause auto-switching for:")
                    .font(.caption).foregroundStyle(.secondary)
                Button("5 min") { state.pauseAutoSwitch(for: 5 * 60) }.controlSize(.small)
                Button("30 min") { state.pauseAutoSwitch(for: 30 * 60) }.controlSize(.small)
                Button("2 hr") { state.pauseAutoSwitch(for: 2 * 60 * 60) }.controlSize(.small)
            }
        }
    }
}

private struct HeaderBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Text("auto-wifi")
                .font(.title2.weight(.semibold))

            Picker("Auto-switch", selection: Binding(get: { state.decisions.mode }, set: { state.decisions.setMode($0) })) {
                ForEach(AutoSwitchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .help(state.decisions.mode.description)

            Spacer()

            Text("scan: \(state.scan.cadence.label) (\(state.scan.cadence.interval.humanShort))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            if let when = state.scan.lastScannedAt {
                Text(when.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                Task { await state.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct FSMBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let fsm = state.decisions.engineState.fsm
        HStack(spacing: 12) {
            Image(systemName: icon(for: fsm))
                .imageScale(.large)
                .foregroundStyle(color(for: fsm))
            VStack(alignment: .leading, spacing: 2) {
                Text("Engine state: \(label(for: fsm))")
                    .font(.headline)
                Text(description(for: fsm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.decisions.mode.label.uppercased())
                .font(.caption.bold().monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(state.decisions.mode == .on ? Color.orange.opacity(0.2) : Color.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(state.decisions.mode == .on ? .orange : .secondary)
        }
        .padding(16)
        .background(color(for: fsm).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func icon(for s: DecisionState.FSM) -> String {
        switch s {
        case .off: "power"
        case .steady: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .switching: "arrow.triangle.2.circlepath"
        case .cooldown: "hourglass"
        }
    }

    private func color(for s: DecisionState.FSM) -> Color {
        switch s {
        case .off: .secondary
        case .steady: .green
        case .degraded: .orange
        case .switching: .blue
        case .cooldown: .yellow
        }
    }

    private func label(for s: DecisionState.FSM) -> String {
        s.rawValue.uppercased()
    }

    private func description(for s: DecisionState.FSM) -> String {
        switch s {
        case .off: "Engine is paused."
        case .steady: "Current connection is healthy. No switch considered."
        case .degraded: "Current connection is below the good-enough threshold. Evaluating candidates."
        case .switching: "A better candidate passed all hysteresis gates."
        case .cooldown: "Recently switched — frozen briefly so the new connection can settle."
        }
    }
}

private struct CurrentConnectionCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wifi").foregroundStyle(.tint)
                Text("Current connection").font(.headline)
            }
            let snap = state.scan.snapshot
            if let ssid = snap.currentSSID {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
                    row("SSID", ssid)
                    row("BSSID", snap.currentBSSID ?? "—")
                    row("RSSI", snap.currentRSSI.map { "\($0) dBm" } ?? "—")
                    row("Channel", snap.currentChannel.map(String.init) ?? "—")
                    row("Band", snap.currentBand?.rawValue ?? "—")
                }
            } else if let err = state.scan.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            } else {
                Text("Not connected to a Wi-Fi network.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.subheadline).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private struct HealthCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.tint)
                Text("Connection health").font(.headline)
                Spacer()
                Text(state.health.lastSample.measuredAt.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            let h = state.health.lastSample
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Latency", latencyLabel(h.latencyMillis), tint: latencyColor(h.latencyMillis))
                row("Connectivity", h.dnsSuccess ? "OK" : "down", tint: h.dnsSuccess ? .green : .red)
                row("Captive portal", state.captiveVerdict.map { $0.captive ? "yes" : "no" } ?? "not yet probed", tint: state.captiveVerdict?.captive == true ? .red : .secondary)
                row("Path type", pathLabel(expensive: h.isExpensive, constrained: h.isConstrained, connected: h.isConnected), tint: .secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, tint: Color) -> some View {
        GridRow {
            Text(label).font(.subheadline).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(tint).textSelection(.enabled)
        }
    }

    private func latencyLabel(_ ms: Double?) -> String { ms.map { String(format: "%.0f ms", $0) } ?? "—" }
    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .secondary }
        switch ms {
        case ..<50: return .green
        case ..<150: return .yellow
        case ..<400: return .orange
        default: return .red
        }
    }
    private func pathLabel(expensive: Bool, constrained: Bool, connected: Bool) -> String {
        if !connected { return "no network path" }
        var l: [String] = ["connected"]
        if expensive { l.append("metered") }
        if constrained { l.append("low-data mode") }
        return l.joined(separator: ", ")
    }
}

private struct LastDecisionCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundStyle(.tint)
                Text("Last decision").font(.headline)
            }
            if let d = state.decisions.lastDecision {
                HStack(spacing: 10) {
                    DecisionActionBadge(action: d.action)
                    Text(d.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Text(d.reason)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No decisions yet. The engine evaluates every 2 seconds.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct KnownInRangeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Known networks in range").font(.headline)
                Text("(\(state.scan.snapshot.knownInRange.count))").foregroundStyle(.secondary)
            }
            if state.scan.snapshot.knownInRange.isEmpty {
                Text("No known networks visible right now.")
                    .foregroundStyle(.secondary).font(.callout).padding(.vertical, 6)
            } else {
                CandidateTable(candidates: state.scan.snapshot.knownInRange)
            }
        }
    }
}

private struct DecisionLogSection: View {
    @Environment(AppState.self) private var state
    @State private var filter: DecisionLoop.Filter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.tint)
                Text("Decision log").font(.headline)
                Text("(\(state.decisions.log.count))").foregroundStyle(.secondary)
                Spacer()
                Picker("Filter", selection: $filter) {
                    ForEach(DecisionLoop.Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button("Clear") { state.decisions.clearLog() }
                    .disabled(state.decisions.log.isEmpty)
            }
            let entries = state.decisions.filteredLog(filter).reversed()
            if entries.isEmpty {
                Text("No matching decisions yet.")
                    .foregroundStyle(.secondary).font(.callout).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(50)), id: \.id) { d in
                        DecisionRow(decision: d)
                        Divider()
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct DecisionRow: View {
    let decision: Decision

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DecisionActionBadge(action: decision.action)
                .frame(minWidth: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.reason)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(decision.timestamp.formatted(date: .omitted, time: .standard))  ·  fsm: \(decision.fsmStateAfter.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct DecisionActionBadge: View {
    let action: Decision.Action

    var body: some View {
        Text(label).font(.caption.bold().monospaced())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch action {
        case .stay: "STAY"
        case .stayCurrentGoodEnough: "GOOD"
        case .rejectedSwitch: "REJECT"
        case .rejectedSwitchCooldown: "COOLDOWN"
        case .switchTo: "SWITCH"
        case .noCurrentConnection: "NO-CONN"
        }
    }

    private var color: Color {
        switch action {
        case .stay, .stayCurrentGoodEnough: .green
        case .rejectedSwitch, .rejectedSwitchCooldown: .orange
        case .switchTo: .blue
        case .noCurrentConnection: .secondary
        }
    }
}

private struct AllInRangeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DisclosureGroup {
            CandidateTable(candidates: state.scan.snapshot.allInRange).padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text("All networks visible (\(state.scan.snapshot.allInRange.count))").font(.headline)
            }
        }
    }
}

private struct CandidateTable: View {
    let candidates: [Candidate]

    var body: some View {
        Table(candidates) {
            TableColumn("SSID") { c in
                HStack(spacing: 6) {
                    if c.isKnown {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).imageScale(.small)
                    }
                    Text(c.scan.ssid).textSelection(.enabled)
                }
            }
            TableColumn("RSSI") { c in
                Text("\(c.scan.rssi) dBm").monospacedDigit().foregroundStyle(rssiColor(c.scan.rssi))
            }.width(min: 70, max: 90)
            TableColumn("Band") { c in
                Text(c.scan.band.rawValue).monospacedDigit()
            }.width(min: 50, max: 70)
            TableColumn("Channel") { c in
                Text("\(c.scan.channel)").monospacedDigit()
            }.width(min: 60, max: 80)
            TableColumn("BSSID") { c in
                Text(c.scan.bssid ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(c.scan.bssid == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }.width(min: 140, max: 180)
        }
        .frame(minHeight: CGFloat(min(candidates.count, 10)) * 28 + 32)
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-80): return .red
        case ..<(-70): return .orange
        case ..<(-60): return .yellow
        default: return .green
        }
    }
}

private extension Duration {
    var humanShort: String {
        let secs = Double(self.components.seconds)
        if secs < 60 { return String(format: "%.0fs", secs) }
        return String(format: "%.0fm", secs / 60)
    }
}
