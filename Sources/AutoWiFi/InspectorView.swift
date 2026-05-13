import SwiftUI
import Core

/// The main user-facing surface for Phases 1-2: a live readout of the current connection
/// (now with health metrics) plus a table of nearby known networks. Phases 4-6 layer
/// score/decision-log columns onto the same tables.
struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CurrentConnectionCard()
                    HealthCard()
                    KnownInRangeSection()
                    AllInRangeSection()
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HeaderBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Text("auto-wifi")
                .font(.title2.weight(.semibold))

            Spacer()

            Text(cadenceLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            if let when = state.scan.lastScannedAt {
                Text("Updated \(when.formatted(date: .omitted, time: .standard))")
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

    private var cadenceLabel: String {
        "scan: \(state.scan.cadence.label) (\(state.scan.cadence.interval.humanShort))"
    }
}

private struct CurrentConnectionCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                Text("Current connection")
                    .font(.headline)
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
                Text("Not connected to a Wi-Fi network.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct HealthCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.tint)
                Text("Connection health")
                    .font(.headline)
                Spacer()
                Text(state.health.lastSample.measuredAt.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
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
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
        }
    }

    private func latencyLabel(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.0f ms", ms)
    }

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
        var labels: [String] = ["connected"]
        if expensive { labels.append("metered") }
        if constrained { labels.append("low-data mode") }
        return labels.joined(separator: ", ")
    }
}

private struct KnownInRangeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Known networks in range")
                    .font(.headline)
                Text("(\(state.scan.snapshot.knownInRange.count))")
                    .foregroundStyle(.secondary)
            }
            if state.scan.snapshot.knownInRange.isEmpty {
                Text("No known networks visible right now.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 6)
            } else {
                CandidateTable(candidates: state.scan.snapshot.knownInRange)
            }
        }
    }
}

private struct AllInRangeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DisclosureGroup {
            CandidateTable(candidates: state.scan.snapshot.allInRange)
                .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text("All networks visible (\(state.scan.snapshot.allInRange.count))")
                    .font(.headline)
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
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .imageScale(.small)
                    }
                    Text(c.scan.ssid).textSelection(.enabled)
                }
            }
            TableColumn("RSSI") { c in
                Text("\(c.scan.rssi) dBm")
                    .monospacedDigit()
                    .foregroundStyle(rssiColor(c.scan.rssi))
            }
            .width(min: 70, max: 90)
            TableColumn("Band") { c in
                Text(c.scan.band.rawValue).monospacedDigit()
            }
            .width(min: 50, max: 70)
            TableColumn("Channel") { c in
                Text("\(c.scan.channel)").monospacedDigit()
            }
            .width(min: 60, max: 80)
            TableColumn("BSSID") { c in
                Text(c.scan.bssid ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(c.scan.bssid == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .width(min: 140, max: 180)
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
