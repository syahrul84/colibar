import ColibarCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updates: UpdateManager
    @Binding var isPresented: Bool

    init(isPresented: Binding<Bool>, updates: UpdateManager) {
        _isPresented = isPresented
        self.updates = updates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Refresh every", selection: $appState.refreshInterval) {
                ForEach(AppState.refreshIntervalChoices, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Show stopped containers", isOn: $appState.showStoppedContainers)

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
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}
