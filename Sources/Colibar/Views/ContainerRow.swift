import ColibarCore
import SwiftUI

struct ContainerRow: View {
    @EnvironmentObject private var appState: AppState
    let container: DockerContainer
    @State private var hovering = false
    @State private var editingHost = false

    private var isBusy: Bool { appState.busyContainers.contains(container.id) }
    private var stats: ContainerStats? { appState.statsByID[container.id] }
    private var mapping: CustomHostMapping? { appState.hostMapping(for: container) }

    var body: some View {
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if container.isRunning, let usage = usageLine {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer()
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering = $0 }
        .help(hoverDetail)
        .contextMenu {
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

    /// "Up 4 days (healthy)" / "Exited (255) 4 days ago" — docker's own words,
    /// so running vs stopped is spelled out rather than implied by a dot.
    /// The primary runtime version rides along; the full probed list (npm,
    /// composer, …) lives in the hover tooltip to keep rows compact.
    private var subtitle: String {
        var parts: [String] = [container.status.isEmpty ? container.state : container.status]
        if let size = container.displaySize { parts.append(size) }
        if let version = primaryVersion { parts.append(version) }
        return parts.joined(separator: " · ")
    }

    /// Probed truth first, image-tag hint as immediate fallback.
    private var primaryVersion: String? {
        if let probed = appState.versionsByID[container.id] {
            return probed.components(separatedBy: " · ").first
        }
        return container.tagVersion
    }

    private var hoverDetail: String {
        if let probed = appState.versionsByID[container.id] {
            return "\(container.status)\n\(probed)"
        }
        return container.status
    }

    private var usageLine: String? {
        guard let stats else { return nil }
        var parts: [String] = []
        if let cpu = stats.cpuPercent { parts.append(String(format: "CPU %.1f%%", cpu)) }
        if let mem = stats.memUsage {
            if let pct = stats.memPercent {
                parts.append(String(format: "MEM %@ (%.1f%%)", mem, pct))
            } else {
                parts.append("MEM \(mem)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
