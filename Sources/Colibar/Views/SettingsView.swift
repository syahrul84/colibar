import ColibarCore
import SwiftUI

/// The Settings window (a real window, not panel-embedded — the panel got
/// too cramped): two tabs, General and Display.
struct SettingsRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab(updates: appState.updates)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "eye") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var updates: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Refresh every", selection: $appState.refreshInterval) {
                ForEach(AppState.refreshIntervalChoices, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Notify when a container stops unexpectedly", isOn: $appState.notifyOnCrash)

            Toggle("Start Colima when Colibar opens", isOn: $appState.autoStartColima)

            Toggle("Launch at login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            ))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Local .test domains", isOn: Binding(
                    get: { appState.localDomainsEnabled },
                    set: { appState.setLocalDomains($0) }
                ))
                Text("Turns on the built-in proxy. Map individual containers from their rows — hover a container and click the globe next to its port to give it a name like goodbite.test. Only mapped containers are added to /etc/hosts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.localDomainsEnabled {
                    Toggle("HTTPS (trust local certificate)", isOn: Binding(
                        get: { appState.httpsEnabled },
                        set: { appState.setHTTPS($0) }
                    ))
                    Text("Colibar signs certificates with its own local CA — trusting it once (macOS shows a trust-settings dialog) makes https://project.test valid in the browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !appState.customHosts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(appState.customHosts.sorted(by: { $0.host < $1.host })) { mapping in
                                HStack(spacing: 6) {
                                    Text(mapping.host)
                                        .font(.caption.monospaced())
                                    Text("→ :\(String(mapping.port))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        appState.openMappedHost(mapping)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Open \(mapping.host)")
                                    Button {
                                        appState.removeHostMapping(host: mapping.host)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove \(mapping.host)")
                                }
                            }
                            Text("Edit a mapping from its container's row.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 2)
                    }

                    if appState.hostsOutOfSync {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("Projects changed — /etc/hosts needs updating.")
                                .font(.caption)
                            Button("Update Hosts") { appState.applyHostsFile() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Binaries are looked up in Homebrew and system paths, then cached. Re-scan if you've just installed colima or docker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Re-scan Binaries") {
                    appState.rescanBinaries()
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(updates.checking ? "Checking…" : "Check for Updates") {
                        updates.check(manual: true)
                    }
                    .controlSize(.small)
                    .disabled(updates.checking || updates.installing)
                    Text("v\(updates.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let status = updates.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let update = updates.available {
                    HStack(spacing: 8) {
                        Text("Version \(update.version) is available.")
                            .font(.caption.weight(.medium))
                        Button(updates.installing ? "Installing…" : "Install & Relaunch") {
                            updates.install()
                        }
                        .controlSize(.small)
                        .disabled(updates.installing)
                    }
                }
                Toggle("Check for updates automatically", isOn: $appState.autoCheckUpdates)

                if !appState.brewOutdated.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.brewOutdated, id: \.name) { item in
                            Text("\(item.name) \(item.installed) → \(item.latest)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button("Update in Terminal") { appState.upgradeToolchain() }
                                .controlSize(.small)
                            Text("Runs brew where you can watch it.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if appState.brewOutdated.contains(where: { $0.name == "colima" }) {
                            Text("A colima upgrade applies after the VM restarts — use the instance's restart when convenient.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(AppLinks.kofi)
                } label: {
                    Label("Send a Tip", systemImage: "cup.and.saucer.fill")
                }
                .controlSize(.small)
                .help("Buy me a coffee on Ko-fi")
                Button {
                    NSWorkspace.shared.open(AppLinks.github)
                } label: {
                    Label("Star on GitHub", systemImage: "star.fill")
                }
                .controlSize(.small)
                .help("Star the Colibar repository")
                Spacer()
            }
        }
        .padding(16)
    }
}

// MARK: - Display

struct DisplaySettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmingTeardownID: String?

    /// All compose projects, including currently hidden ones (this is where
    /// they get unhidden).
    private var projectGroups: [ContainerGroup] {
        appState.groups.filter { $0.project != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SHOW IN LIST")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle("Colima instances", isOn: $appState.showInstances)
                Toggle("Usage stats (CPU & RAM)", isOn: $appState.showUsageStats)
                Toggle("Stopped containers", isOn: $appState.showStoppedContainers)
                Toggle("“Other” (non-compose) containers", isOn: $appState.showOtherGroup)
            }

            if !projectGroups.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROJECTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(projectGroups) { group in
                        ProjectSettingsRow(group: group, confirmingID: $confirmingTeardownID)
                    }
                    Text("Unchecking hides a project from the list. The trash button deletes its containers and images — source files and data volumes are kept, and the project comes back with docker compose up.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// One project in Display settings: visibility checkbox + delete-runtime
/// button with inline confirmation.
private struct ProjectSettingsRow: View {
    @EnvironmentObject private var appState: AppState
    let group: ContainerGroup
    @Binding var confirmingID: String?

    private var isBusy: Bool { appState.busyGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(group.title, isOn: Binding(
                    get: { !appState.hiddenProjectIDs.contains(group.id) },
                    set: { appState.setProjectHidden(group.id, hidden: !$0) }
                ))
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        confirmingID = confirmingID == group.id ? nil : group.id
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete \(group.title)'s containers and images")
                }
            }
            if confirmingID == group.id, !isBusy {
                HStack(spacing: 8) {
                    Text("Delete \(group.title)'s containers and images? Files and data volumes are kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { confirmingID = nil }
                        .controlSize(.small)
                    Button("Delete", role: .destructive) {
                        confirmingID = nil
                        appState.teardownGroup(group)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
