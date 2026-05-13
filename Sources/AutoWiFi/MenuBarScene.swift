import SwiftUI
import Core
import Algorithms

/// UI-01: MenuBarExtra item — the always-present surface. Title shows the current SSID +
/// status glyph; the menu contains the mode toggle, pause buttons, the live RSSI/score,
/// and links to the main window and quit.
struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CurrentRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            ModeRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            PauseRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if state.guards.isHeld {
                Divider()
                HoldStatusRow()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()

            ActionsRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
    }
}

private struct CurrentRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: stateGlyph)
                    .foregroundStyle(stateColor)
                Text(state.scan.snapshot.currentSSID ?? "Not connected")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 14) {
                if let rssi = state.scan.snapshot.currentRSSI {
                    Label("\(rssi) dBm", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.monospacedDigit())
                }
                if let ms = state.health.lastSample.latencyMillis {
                    Label("\(Int(ms)) ms", systemImage: "waveform.path.ecg")
                        .font(.caption.monospacedDigit())
                }
                if state.captiveVerdict?.captive == true {
                    Label("captive", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var stateGlyph: String {
        switch state.decisions.engineState.fsm {
        case .off: "power"
        case .steady: "wifi"
        case .degraded: "wifi.exclamationmark"
        case .switching: "arrow.triangle.2.circlepath"
        case .cooldown: "hourglass"
        }
    }

    private var stateColor: Color {
        switch state.decisions.engineState.fsm {
        case .off: .secondary
        case .steady: .green
        case .degraded: .orange
        case .switching: .blue
        case .cooldown: .yellow
        }
    }
}

private struct ModeRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-switch")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { state.decisions.mode }, set: { state.decisions.setMode($0) })) {
                ForEach(AutoSwitchMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct PauseRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause auto-switching")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("5 min") { state.pauseAutoSwitch(for: 5 * 60) }
                Button("30 min") { state.pauseAutoSwitch(for: 30 * 60) }
                Button("2 hr") { state.pauseAutoSwitch(for: 2 * 60 * 60) }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}

private struct HoldStatusRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paused")
                    .font(.callout.weight(.medium))
                if let reason = state.guards.holdReason {
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Resume") { state.clearAllHolds() }.controlSize(.small)
        }
    }
}

private struct ActionsRow: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open main window", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit auto-wifi", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Title of the MenuBarExtra in the system menubar. Uses a system icon so the title isn't
/// dependent on a custom asset (which would need an asset catalog).
struct MenuBarTitle: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
            if let ssid = state.scan.snapshot.currentSSID, !ssid.isEmpty {
                Text(ssid)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var glyph: String {
        switch state.decisions.engineState.fsm {
        case .off: "wifi.slash"
        case .steady: "wifi"
        case .degraded: "wifi.exclamationmark"
        case .switching: "arrow.triangle.2.circlepath"
        case .cooldown: "hourglass"
        }
    }
}
