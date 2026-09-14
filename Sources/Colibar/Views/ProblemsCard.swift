import ColibarCore
import SwiftUI

/// The "why is there a warning triangle" card: every container that is
/// unhealthy, restart-looping, or dead, with the reason in words and a
/// restart button as the first-line remedy.
struct ProblemsCard: View {
    @EnvironmentObject private var appState: AppState

    private var problems: [DockerContainer] {
        appState.groups.flatMap(\.containers).filter(\.hasProblem)
    }

    var body: some View {
        if !problems.isEmpty || !appState.diskWarnings.isEmpty || !appState.unnamedProjects.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                ForEach(appState.diskWarnings, id: \.instance) { warning in
                    DiskWarningRow(warning: warning)
                }
                ForEach(appState.unnamedProjects) { warning in
                    UnnamedProjectRow(warning: warning)
                }
                ForEach(problems) { container in
                    ProblemRow(container: container)
                }
            }
            .padding(.bottom, 6)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Disk-full warning with one-click cleanup. First click asks inline; the
/// prune removes unused images and build cache only — never containers,
/// volumes, or networks.
private struct DiskWarningRow: View {
    @EnvironmentObject private var appState: AppState
    let warning: (instance: String, percent: Int)
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                Text("VM disk \(warning.percent)% full (\(warning.instance)) — unused images and build cache pile up quietly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if appState.pruning {
                    ProgressView()
                        .controlSize(.small)
                } else if !confirming {
                    Button("Reclaim Space…") { confirming = true }
                        .controlSize(.small)
                }
            }
            if confirming, !appState.pruning {
                HStack(spacing: 8) {
                    Text("Remove images and build cache no container uses? Containers and volumes are untouched.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { confirming = false }
                        .controlSize(.small)
                    Button("Prune") {
                        confirming = false
                        appState.pruneDisk()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

/// Advisory: a compose project running on its folder-name default. The user
/// confirms (or edits) the suggested name before anything is written to the
/// compose file; applies on the project's next compose up.
private struct UnnamedProjectRow: View {
    @EnvironmentObject private var appState: AppState
    let warning: AppState.UnnamedProjectWarning
    @State private var editing = false
    @State private var name = ""

    private var cleaned: String { ComposeNameAdvisor.sanitize(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tag")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                Text("“\(warning.title)” has no explicit project name — same-named folders can clobber each other's containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !editing {
                    Button("Add Name…") {
                        name = warning.suggestion
                        editing = true
                    }
                    .controlSize(.small)
                }
            }
            if editing {
                HStack(spacing: 6) {
                    Text("name:")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextField("project-name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 150)
                    Spacer()
                    Button("Cancel") { editing = false }
                        .controlSize(.small)
                    Button("Save") {
                        editing = false
                        appState.fixProjectName(warning, name: cleaned)
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                }
                if !cleaned.isEmpty, cleaned != name {
                    Text("Will be saved as “\(cleaned)” (compose allows a–z, 0–9, - and _)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("Written to the compose file · applies on next docker compose up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct ProblemRow: View {
    @EnvironmentObject private var appState: AppState
    let container: DockerContainer

    private var isBusy: Bool { appState.busyContainers.contains(container.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: .transitional)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(container.displayName)
                        .font(.callout.weight(.medium))
                    if let project = container.composeProject {
                        Text("· \(project)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(container.problemReason ?? "Problem")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 3)
            } else {
                RowActionButton(
                    systemImage: "arrow.clockwise",
                    help: "Restart \(container.displayName)"
                ) {
                    appState.restartContainer(container)
                }
                RowActionButton(systemImage: "stop.fill", help: "Stop \(container.displayName)") {
                    appState.stopContainer(container)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contextMenu {
            Button("View Logs") { appState.openLogs(container) }
            Button("Copy ID") { appState.copyToClipboard(container.shortID) }
        }
    }
}
