import ColibarCore
import SwiftUI

struct InstanceRow: View {
    @EnvironmentObject private var appState: AppState
    let instance: ColimaInstance
    @State private var hovering = false

    private var isBusy: Bool { appState.busyInstances.contains(instance.name) }

    private func usageLine(_ usage: AppState.UsageSummary) -> String {
        var line = usage.label
        if let disk = appState.diskUsage[instance.name] {
            line += " · Disk \(disk)%"
        }
        return line
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(on: instance.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.name)
                    .font(.callout.weight(.medium))
                Text(isBusy ? "Working…" : "\(instance.status.label) · \(instance.specsDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isBusy, instance.isRunning, let usage = appState.overallUsage {
                    Text(usageLine(usage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                RowActionButton(
                    systemImage: "slider.horizontal.3",
                    help: "Edit CPU, memory and disk for \(instance.name)"
                ) {
                    appState.editingInstance = instance
                }
                if instance.isRunning {
                    RowActionButton(systemImage: "stop.fill", help: "Stop \(instance.name)") {
                        appState.stopInstance(instance)
                    }
                } else {
                    RowActionButton(systemImage: "play.fill", help: "Start \(instance.name)") {
                        appState.startInstance(instance)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Restart") { appState.restartInstance(instance) }
                .disabled(isBusy || !instance.isRunning)
            Button("Edit Resources…") { appState.editingInstance = instance }
                .disabled(isBusy)
        }
    }
}

struct StatusDot: View {
    enum DotState {
        case on, off, transitional
    }

    let state: DotState

    init(state: DotState) { self.state = state }
    init(on: Bool) { state = on ? .on : .off }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        switch state {
        case .on: return .green
        case .off: return .red.opacity(0.7)
        case .transitional: return .orange
        }
    }
}

struct RowActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
