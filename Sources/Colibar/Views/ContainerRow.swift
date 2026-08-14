import ColibarCore
import SwiftUI

struct ContainerRow: View {
    @EnvironmentObject private var appState: AppState
    let container: DockerContainer
    @State private var hovering = false
    @State private var editingHost = false
    /// Slide-down detail section; per-row, survives refreshes because the
    /// ForEach identity (container ID) is stable.
    @State private var expanded = false

    private var isBusy: Bool { appState.busyContainers.contains(container.id) }
    private var stats: ContainerStats? { appState.statsByID[container.id] }
    private var mapping: CustomHostMapping? { appState.hostMapping(for: container) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                detailSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    // MARK: - Compact row: name, ports, CPU/MEM only

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: dotState)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(container.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let port = container.hostPorts.first {
                        PortBadge(port: port, extraCount: container.hostPorts.count - 1) {
                            appState.openInBrowser(container, port: port)
                        }
                    }
                    if appState.localDomainsEnabled, !container.hostPorts.isEmpty {
                        HostButton(
                            mapping: mapping,
                            visible: hovering || mapping != nil,
                            open: { if let mapping { appState.openMappedHost(mapping) } },
                            edit: { editingHost = true },
                            remove: { appState.removeHostMapping(for: container) }
                        )
                        .popover(isPresented: $editingHost, arrowEdge: .bottom) {
                            HostEditorView(
                                container: container,
                                isPresented: $editingHost,
                                existing: mapping
                            )
                            .environmentObject(appState)
                        }
                    }
                }
                Text(compactSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Hide details" : "Show details")
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 3)
            } else if container.isRunning {
                RowActionButton(systemImage: "stop.fill", help: "Stop \(container.displayName)") {
                    appState.stopContainer(container)
                }
            } else {
                RowActionButton(systemImage: "play.fill", help: "Start \(container.displayName)") {
                    appState.startContainer(container)
                }
            }
        }
    }

    /// Running: processor and memory only. Stopped: docker's status line,
    /// since there is no usage to show and the reason matters.
    private var compactSubtitle: String {
        guard container.isRunning else {
            return container.status.isEmpty ? container.state : container.status
        }
        guard let stats else { return "measuring…" }
        var parts: [String] = []
        if let cpu = stats.cpuPercent { parts.append(String(format: "CPU %.1f%%", cpu)) }
        if let mem = stats.memUsage { parts.append("MEM \(mem)") }
        return parts.isEmpty ? "measuring…" : parts.joined(separator: " · ")
    }

    // MARK: - Slide-down details

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            detailLine("Status", container.status.isEmpty ? container.state : container.status)
            detailLine("Image", container.image)
            if let size = container.displaySize {
                detailLine("Size", size)
            }
            if !container.hostPorts.isEmpty {
                detailLine("Ports", container.hostPorts.map { ":\(String($0))" }.joined(separator: "  "))
            }
            if let versions = versionLines {
                ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                    detailLine(index == 0 ? "Versions" : "", version)
                }
            } else if container.isRunning {
                detailLine("Versions", "probing…")
            }
            detailLine("ID", container.shortID)
        }
        .padding(.top, 6)
        .padding(.leading, 17)
        .padding(.bottom, 2)
    }

    private var versionLines: [String]? {
        if let probed = appState.versionsByID[container.id] {
            return probed.components(separatedBy: " · ")
        }
        if let tag = container.tagVersion {
            return [tag]
        }
        return nil
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var menuItems: some View {
        Button("Restart") { appState.restartContainer(container) }
            .disabled(isBusy)
        Divider()
        Button("View Logs") { appState.openLogs(container) }
        Button("Open Shell") { appState.openShell(container) }
            .disabled(!container.isRunning)
        if !container.hostPorts.isEmpty {
            Divider()
            ForEach(container.hostPorts, id: \.self) { port in
                Button(openLabel(port: port)) { appState.openInBrowser(container, port: port) }
            }
            if appState.localDomainsEnabled {
                Button(mapping == nil ? "Set Host…" : "Edit Host…") { editingHost = true }
            }
        }
        Divider()
        if let connection = container.connectionURL {
            Button("Copy Connection URL") { appState.copyToClipboard(connection) }
        }
        Button("Copy ID") { appState.copyToClipboard(container.shortID) }
        Button("Copy Name") { appState.copyToClipboard(container.name) }
    }

    private func openLabel(port: Int) -> String {
        if let url = appState.webURL(for: container, port: port), url.host != "localhost" {
            return "Open \(url.host ?? "")"
        }
        return "Open localhost:\(String(port))"
    }

    private var dotState: StatusDot.DotState {
        if container.isUnhealthy || container.isTransitional { return .transitional }
        if container.isRunning { return .on }
        return .off
    }
}

/// "host" affordance beside the port badge. No mapping: a quiet globe on
/// hover that opens the editor. Mapped: a green hostname pill whose click
/// menu offers Open / Edit / Remove.
struct HostButton: View {
    let mapping: CustomHostMapping?
    let visible: Bool
    let open: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        Group {
            if let mapping {
                Menu {
                    Button("Open \(mapping.host)", action: open)
                    Button("Edit…", action: edit)
                    Divider()
                    Button("Remove Host", role: .destructive, action: remove)
                } label: {
                    Text(mapping.host)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(mapping.host)
            } else {
                Button(action: edit) {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Set a .test hostname for this container")
            }
        }
        .opacity(visible ? 1 : 0)
    }
}

struct PortBadge: View {
    let port: Int
    let extraCount: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text(extraCount > 0 ? ":\(String(port)) +\(extraCount)" : ":\(String(port))")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .help("Open localhost:\(String(port)) in your browser")
    }
}
