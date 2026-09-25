import ColibarCore
import SwiftUI

/// Reports the natural height of the scrollable content so the panel can
/// size itself. MenuBarExtra windows hug their content's *ideal* height, and
/// a ScrollView's ideal height is zero — without this the panel collapses to
/// just the header.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Scroll container that reports its content's natural height and sizes
/// itself to it (capped), so every panel mode — list, settings, editors —
/// gets the same "hug content, scroll past 480pt" behavior.
struct MeasuredScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 60), 480))
    }
}

/// Keeps the panel glued to the menu bar. MenuBarExtra reuses its window
/// across opens, and when the content height changes (our measured scroll
/// area, collapsing cards, the Attention card) recent macOS anchors the
/// BOTTOM edge — every net shrink walks the top edge down, leaving a
/// widening gap under the bar that persists into the next open. This view
/// re-pins the window's top to the menu bar whenever geometry updates.
private struct PanelWindowPinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PinView)?.scheduleRepin()
    }

    final class PinView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRepin()
        }

        func scheduleRepin() {
            // After the current layout pass, so the new height is applied.
            DispatchQueue.main.async { [weak self] in self?.repin() }
        }

        private func repin() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let top = screen.visibleFrame.maxY // just under the menu bar
            let frame = window.frame
            guard abs(frame.maxY - top) > 1 else { return }
            window.setFrame(
                NSRect(x: frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
                display: true
            )
        }
    }
}

/// Root of the menu bar window: header, instances, containers, footer.
struct PanelView: View {
    @EnvironmentObject private var appState: AppState
    /// The supported way to open the Settings scene on macOS 14+ — the old
    /// showSettingsWindow: selector is no longer honored.
    @Environment(\.openSettings) private var openSettings

    private func openSettingsWindow() {
        revealSettingsWindow(openSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 340)
        .background(PanelWindowPinner())
        .onAppear { appState.panelDidOpen() }
        .onDisappear { appState.panelDidClose() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let mark = BrandMark.shared.templateImage {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.tint)
            }
            Text("Colibar")
                .font(.headline)
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            Spacer()
            Button {
                appState.manualRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Colibar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !appState.colimaInstalled {
            ColimaMissingView()
        } else if !appState.hasLoadedOnce {
            loading
        } else {
            searchField
            Divider()
            MeasuredScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ProblemsCard()
                    if appState.showInstances {
                        instancesSection
                    }
                    containersSection
                }
                .padding(12)
            }
            if let status = appState.statusMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = appState.lastError {
                Divider()
                ErrorBanner(message: error)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter containers", text: $appState.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if appState.isSearching {
                Button {
                    appState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 24)
    }

    private var instancesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Colima")
            if appState.instances.isEmpty {
                Text("No Colima instances found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.instances) { instance in
                    InstanceRow(instance: instance)
                }
            }
        }
    }

    @ViewBuilder
    private var containersSection: some View {
        let groups = appState.visibleGroups
        let total = appState.groups.reduce(0) { $0 + $1.containers.count }
        let running = appState.groups.reduce(0) { $0 + $1.runningCount }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: total > 0 ? "Containers · \(running)/\(total) running" : "Containers")
            if !appState.instances.contains(where: \.isRunning) {
                EmptyHint(
                    systemImage: "moon.zzz",
                    text: "Colima is stopped. Start an instance to see containers."
                )
            } else if !appState.dockerInstalled {
                EmptyHint(
                    systemImage: "questionmark.folder",
                    text: "The docker CLI is missing. Install it with: brew install docker — then Re-scan in Settings."
                )
            } else if appState.dockerUnreachable {
                EmptyHint(
                    systemImage: "bolt.horizontal.circle",
                    text: "Docker isn't reachable yet — retrying on the next refresh."
                )
            } else if groups.isEmpty {
                EmptyHint(
                    systemImage: appState.isSearching ? "magnifyingglass" : "shippingbox",
                    text: appState.isSearching
                        ? "Nothing matches “\(appState.searchText)”."
                        : appState.showStoppedContainers
                            ? "No containers yet."
                            : "No running containers. Stopped ones are hidden in Settings."
                )
            } else {
                ForEach(groups) { group in
                    GroupCard(group: group)
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

struct EmptyHint: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown when the colima binary can't be found anywhere.
struct ColimaMissingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Colima not found", systemImage: "questionmark.folder")
                .font(.headline)
            Text("Colibar couldn't find the colima binary. Install it with Homebrew:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("brew install colima docker")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("Scan Again") {
                appState.rescanBinaries()
            }
        }
        .padding(12)
    }
}
