import ColibarCore
import SwiftUI

/// Collapsible card for one compose project (or the "Other" bucket).
struct GroupCard: View {
    @EnvironmentObject private var appState: AppState
    let group: ContainerGroup

    // Search results always show their rows; collapsed cards would hide the hits.
    private var collapsed: Bool { !appState.expandedGroups.contains(group.id) && !appState.isSearching }
    private var isBusy: Bool { appState.busyGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if !collapsed {
                Divider()
                    .padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(group.containers) { container in
                        ContainerRow(container: container)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.toggleExpanded(group)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(group.title)
                                .font(.callout.weight(.semibold))
                            Text("\(group.runningCount)/\(group.containers.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        // Usage stays visible while the card is collapsed.
                        if let usage = appState.usageSummary(for: group.containers) {
                            Text(usage.compactLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if group.runningCount < group.containers.count {
                RowActionButton(systemImage: "play.fill", help: "Start all in \(group.title)") {
                    appState.startGroup(group)
                }
            } else {
                RowActionButton(systemImage: "stop.fill", help: "Stop all in \(group.title)") {
                    appState.stopGroup(group)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Restart All Running") { appState.restartGroup(group) }
                .disabled(isBusy || group.runningCount == 0)
            if appState.localDomainsEnabled {
                ForEach(group.containers.compactMap { appState.hostMapping(for: $0) }) { mapping in
                    Button("Open \(mapping.host)") { appState.openMappedHost(mapping) }
                }
            }
            if group.workingDir != nil {
                Divider()
                Button("View Project Logs") { appState.openProjectLogs(group) }
                Button("Open Terminal at Project") { appState.openProjectTerminal(group) }
            }
        }
    }
}
