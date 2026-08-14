import AppKit
import ColibarCore
import SwiftUI

/// Hidden docs tooling: `Colibar --render-screenshot <path>` renders the
/// panel offscreen with demo data and exits. Keeps README screenshots
/// reproducible and free of anyone's real project names.
@MainActor
enum ScreenshotRenderer {
    static func renderIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flag = arguments.firstIndex(of: "--render-screenshot"),
            arguments.indices.contains(flag + 1)
        else { return }
        render(to: arguments[flag + 1])
        exit(0)
    }

    private static func render(to path: String) {
        let state = demoState()
        let view = ScreenshotView()
            .environmentObject(state)
            .frame(width: 340)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let cgImage = renderer.cgImage,
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
            )
        else {
            FileHandle.standardError.write(Data("screenshot render failed\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(path)")
    }

    // MARK: - Demo data

    private static func demoContainer(
        id: String, project: String?, service: String, image: String,
        ports: [Int] = [], state: String = "running", status: String,
        health: String? = nil, size: String? = nil, dir: String? = nil
    ) -> DockerContainer {
        DockerContainer(
            id: id, name: project.map { "\($0)-\(service)-1" } ?? service, image: image,
            state: state, status: status, hostPorts: ports, sizeRaw: size,
            health: health, composeProject: project, composeService: service,
            composeWorkingDir: dir
        )
    }

    private static func demoState() -> AppState {
        let state = AppState()
        state.hasLoadedOnce = true
        state.instances = [
            ColimaInstance(
                name: "default", status: .running, arch: "aarch64", cpus: 4,
                memoryBytes: 8 << 30, diskBytes: 60 << 30, runtime: "docker"
            ),
        ]

        let myshopDir = "/Users/dev/myshop"
        let blogDir = "/Users/dev/blog"
        let containers = [
            demoContainer(
                id: "d1", project: "myshop", service: "app", image: "sail-8.4/app",
                ports: [80], status: "Up 3 hours (healthy)", health: "healthy",
                size: "84.2kB", dir: myshopDir
            ),
            demoContainer(
                id: "d2", project: "myshop", service: "mysql", image: "mysql:8.4",
                ports: [3306], status: "Up 3 hours (healthy)", health: "healthy",
                size: "6.1MB", dir: myshopDir
            ),
            demoContainer(
                id: "d3", project: "myshop", service: "redis", image: "redis:7-alpine",
                ports: [6379], status: "Up 3 hours", size: "0B", dir: myshopDir
            ),
            demoContainer(
                id: "d4", project: "myshop", service: "mailpit", image: "axllent/mailpit:latest",
                ports: [1025, 8025], status: "Up 3 hours (healthy)", health: "healthy",
                size: "0B", dir: myshopDir
            ),
            demoContainer(
                id: "d5", project: "blog", service: "app", image: "sail-8.3/app",
                ports: [8001], status: "Up 2 days", size: "12kB", dir: blogDir
            ),
            demoContainer(
                id: "d6", project: "blog", service: "pgsql", image: "postgres:17",
                ports: [5433], status: "Up 2 days (healthy)", health: "healthy",
                size: "63B", dir: blogDir
            ),
            demoContainer(
                id: "d7", project: nil, service: "sandbox", image: "ubuntu:24.04",
                state: "exited", status: "Exited (0) 5 days ago", size: "12MB"
            ),
        ]
        state.groups = ContainerGroup.group(containers)
        if let myshop = state.groups.first(where: { $0.project == "myshop" }) {
            state.expandedGroups = [myshop.id]
        }

        func stats(_ id: String, cpu: Double, mem: String, pct: Double) -> ContainerStats {
            ContainerStats(
                id: id, cpuPercent: cpu, memUsage: mem, memBytes: ByteSize.parse(mem),
                memLimitBytes: 8 << 30, memPercent: pct, netIO: nil, blockIO: nil, pids: 8
            )
        }
        state.statsByID = [
            "d1": stats("d1", cpu: 1.2, mem: "212MiB", pct: 2.6),
            "d2": stats("d2", cpu: 0.4, mem: "398MiB", pct: 4.9),
            "d3": stats("d3", cpu: 0.2, mem: "9.4MiB", pct: 0.1),
            "d4": stats("d4", cpu: 0.0, mem: "14MiB", pct: 0.2),
            "d5": stats("d5", cpu: 0.6, mem: "164MiB", pct: 2.0),
            "d6": stats("d6", cpu: 0.3, mem: "88MiB", pct: 1.1),
        ]
        state.versionsByID = [
            "d1": "php 8.4.1 · composer 2.8.3 · node 22.11.0 · npm 10.9.0",
            "d2": "mysql 8.4.3",
            "d3": "redis 7.4.1",
            "d5": "php 8.3.14 · composer 2.8.3",
            "d6": "postgres 17.2",
        ]
        state.diskUsage = ["default": 42]
        state.localDomainsEnabled = true
        state.customHosts = [
            CustomHostMapping(host: "myshop.test", containerKey: "myshop/app", port: 80),
        ]
        return state
    }
}

/// The panel recomposed as pure visuals: ImageRenderer can't rasterize
/// Button/Menu controls (they come out as placeholder glyphs), and
/// GeometryReader preferences never settle in a one-shot pass — so the
/// screenshot mirrors the real views' layout with static elements only.
private struct ScreenshotView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Colima")
                instanceRow
                SectionHeader(title: "Containers · 6/7 running")
                ForEach(appState.visibleGroups) { group in
                    groupCard(group)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let url = Bundle.module.url(forResource: "MenuBarMark", withExtension: "png"),
               let mark = NSImage(contentsOf: url) {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.tint)
            }
            Text("Colibar")
                .font(.headline)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.7.0")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Spacer()
            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            Image(systemName: "gearshape").foregroundStyle(.secondary)
            Image(systemName: "power").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var instanceRow: some View {
        HStack(spacing: 8) {
            StatusDot(on: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("default")
                    .font(.callout.weight(.medium))
                Text("Running · 4 CPU · 8 GiB · docker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usage = appState.overallUsage {
                    Text("\(usage.label) · Disk 42%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func groupCard(_ group: ContainerGroup) -> some View {
        let expanded = appState.expandedGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
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
                    if let usage = appState.usageSummary(for: group.containers) {
                        Text(usage.compactLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if expanded {
                Divider()
                    .padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(group.containers) { container in
                        containerRow(container)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: container.isRunning ? .on : .off)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(container.displayName)
                        .font(.callout.weight(.medium))
                    if let mapping = appState.hostMapping(for: container) {
                        badge(mapping.host, color: .green)
                    } else if let port = container.hostPorts.first {
                        badge(
                            container.hostPorts.count > 1 ? ":\(String(port)) +\(container.hostPorts.count - 1)" : ":\(String(port))",
                            color: .accentColor
                        )
                    }
                }
                Text(subtitle(container))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func subtitle(_ container: DockerContainer) -> String {
        guard container.isRunning, let stats = appState.statsByID[container.id] else {
            return container.status
        }
        return String(format: "CPU %.1f%% · RAM %.1f%%", stats.cpuPercent ?? 0, stats.memPercent ?? 0)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
