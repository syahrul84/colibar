import ColibarCore
import Foundation
import os
import ServiceManagement
import SwiftUI
import UserNotifications

let appLog = Logger(subsystem: "com.colibar.Colibar", category: "app")

struct MenuBarSummary: Equatable {
    var anyInstanceRunning = false
    var runningContainers = 0
    /// Any container unhealthy, restart-looping, or dead.
    var hasProblems = false
}

/// Owns all threading, polling, busy-state tracking, and preferences.
/// The only object the views talk to; ColimaService never touches UI and
/// AppState never parses CLI output.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published state

    @Published var instances: [ColimaInstance] = []
    @Published var groups: [ContainerGroup] = []
    @Published var colimaInstalled = true
    /// False when the docker CLI itself is missing (separate brew formula
    /// from colima) — needs an install hint, not a "retrying" message.
    @Published var dockerInstalled = true
    @Published var dockerUnreachable = false
    @Published var lastError: String?
    @Published var hasLoadedOnce = false

    /// Names/IDs with an action in flight — rows show spinners instead of
    /// buttons, and polling pauses so a slow `colima start` doesn't make the
    /// UI flicker between states.
    @Published var busyInstances: Set<String> = []
    @Published var busyContainers: Set<String> = []
    @Published var busyGroups: Set<String> = []

    /// Groups the user has opened this session. Everything starts collapsed
    /// so a fresh panel is a compact list of project summaries.
    @Published var expandedGroups: Set<String> = []

    /// Live filter typed into the panel's search field.
    @Published var searchText = ""
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Latest `docker stats` sample per container ID. Refreshed on its own
    /// cadence because a stats sample takes ~2s.
    @Published var statsByID: [String: ContainerStats] = [:]

    /// VM root-disk usage percent per running instance, refreshed every
    /// couple of minutes while the panel is open. Colima disks silently fill
    /// with old images; surfacing this prevents the classic cryptic failure.
    @Published var diskUsage: [String: Int] = [:]
    static let diskWarningThreshold = 85
    private var lastDiskCheck = Date.distantPast
    private var diskTask: Task<Void, Never>?

    /// Probed runtime versions per container ID ("php 8.3.7 · node 20.1").
    /// Filled lazily by one-time exec probes; IDs never probed twice.
    @Published var versionsByID: [String: String] = [:]
    private var probedIDs: Set<String> = []
    private var versionsTask: Task<Void, Never>?

    @Published var pruning = false
    /// Transient success feedback (e.g. prune results), shown in the panel
    /// footer and cleared automatically.
    @Published var statusMessage: String?

    var diskWarnings: [(instance: String, percent: Int)] {
        diskUsage
            .filter { $0.value >= Self.diskWarningThreshold }
            .map { (instance: $0.key, percent: $0.value) }
            .sorted { $0.instance < $1.instance }
    }

    /// Instance whose resource editor is open (panel navigates to it).
    @Published var editingInstance: ColimaInstance?

    /// Whether the menu bar window is currently on screen. While it's closed
    /// nobody sees per-second detail, so polling drops to a slow heartbeat
    /// (menu bar count + crash notifications still update) and the ~2s
    /// docker-stats sampling stops entirely. Keeps a laptop's battery out of it.
    private var panelVisible = false

    // MARK: - Preferences

    // Deliberately not @AppStorage: inside an ObservableObject it neither
    // publishes changes nor fires didSet when written through a Binding.
    @Published var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartPollTimer()
        }
    }
    @Published var showStoppedContainers: Bool {
        didSet { UserDefaults.standard.set(showStoppedContainers, forKey: "showStoppedContainers") }
    }
    @Published var notifyOnCrash: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnCrash, forKey: "notifyOnCrash")
            if notifyOnCrash { requestNotificationAuthorization() }
        }
    }
    @Published var autoStartColima: Bool {
        didSet { UserDefaults.standard.set(autoStartColima, forKey: "autoStartColima") }
    }
    @Published var localDomainsEnabled: Bool {
        didSet { UserDefaults.standard.set(localDomainsEnabled, forKey: "localDomainsEnabled") }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }

    /// GitHub Releases updater; owns its own published state.
    let updates = UpdateManager()

    /// Outdated colima/docker/docker-compose formulas, checked daily.
    @Published var brewOutdated: [BrewOutdatedItem] = []
    private var brewCheckTask: Task<Void, Never>?
    @Published var httpsEnabled: Bool {
        didSet { UserDefaults.standard.set(httpsEnabled, forKey: "httpsEnabled") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    static let refreshIntervalChoices = [5, 10, 30, 60]

    // MARK: - Internals

    private let service = ColimaService()
    private var pollTimer: Timer?
    private var actionsInFlight = 0
    private var refreshTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    /// Previous refresh's containers, for detecting unexpected transitions.
    private var previousContainers: [String: DockerContainer] = [:]
    /// IDs the user acted on through Colibar — their stops are expected, so
    /// no notification. Cleared once a quiet refresh has passed.
    private var suppressNotificationIDs: Set<String> = []
    private var didAttemptAutoStart = false

    // Local .test domains: hosts-file block + reverse proxy + local CA.
    private let domainService = DomainService()
    private let proxy = ReverseProxy()
    /// User-created hostnames — only containers the user explicitly mapped.
    @Published var customHosts: [CustomHostMapping] = []
    /// True when the desired hosts block differs from what /etc/hosts has.
    /// Never auto-fixed silently on refresh: writing hosts needs an admin
    /// prompt, which should come from a user click.
    @Published var hostsOutOfSync = false
    private var proxyRunning = false
    private var httpsRunning = false
    private var issuedCertHosts: [String] = []

    init() {
        let defaults = UserDefaults.standard
        let storedInterval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = Self.refreshIntervalChoices.contains(storedInterval) ? storedInterval : 10
        showStoppedContainers = defaults.object(forKey: "showStoppedContainers") as? Bool ?? true
        notifyOnCrash = defaults.object(forKey: "notifyOnCrash") as? Bool ?? true
        autoStartColima = defaults.object(forKey: "autoStartColima") as? Bool ?? false
        localDomainsEnabled = defaults.object(forKey: "localDomainsEnabled") as? Bool ?? false
        httpsEnabled = defaults.object(forKey: "httpsEnabled") as? Bool ?? false
        if let data = defaults.data(forKey: "customHostsJSON"),
           let stored = try? JSONDecoder().decode([CustomHostMapping].self, from: data) {
            customHosts = stored
        }
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        if notifyOnCrash { requestNotificationAuthorization() }
        updates.onBackgroundUpdateFound = { [weak self] update in
            self?.postNotification(
                title: "Colibar \(update.version) is available",
                body: "Open Settings to install the update."
            )
        }
        if autoCheckUpdates { updates.autoCheckIfDue() }
        checkToolchainIfDue()
        startPolling()
    }

    /// Daily background `brew outdated` for the toolchain formulas.
    private func checkToolchainIfDue() {
        let last = UserDefaults.standard.double(forKey: "lastBrewCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        runBrewCheck()
    }

    /// The daily cadence finds NEW updates; this one clears STALE ones.
    /// When the panel shows outdated formulas, the user may just have
    /// upgraded them outside Colibar — so re-verify whenever the list is
    /// visible and the user opens the panel or refreshes. Lightly throttled;
    /// no-ops when nothing is displayed.
    private var lastBrewRevalidate = Date.distantPast
    func revalidateToolchainIfNeeded() {
        guard !brewOutdated.isEmpty else { return }
        guard Date().timeIntervalSince(lastBrewRevalidate) > 60 else { return }
        runBrewCheck()
    }

    private func runBrewCheck() {
        guard brewCheckTask == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBrewCheck")
        lastBrewRevalidate = Date()
        let service = self.service
        brewCheckTask = Task { [weak self] in
            let outdated = await Task.detached(priority: .utility) {
                (try? service.checkToolchainOutdated()) ?? []
            }.value
            guard let self else { return }
            appLog.notice("toolchain check: \(outdated.count) outdated\(outdated.isEmpty ? "" : " (\(outdated.map(\.name).joined(separator: ",")))", privacy: .public)")
            self.brewOutdated = outdated
            self.brewCheckTask = nil
        }
    }

    /// The header's refresh button: containers now, plus a stale-row check.
    func manualRefresh() {
        refreshNow()
        revalidateToolchainIfNeeded()
    }

    /// Open Terminal running `brew upgrade` for whatever is behind. The list
    /// clears optimistically; the next daily check re-verifies.
    func upgradeToolchain() {
        let names = brewOutdated.map(\.name)
        guard !names.isEmpty else { return }
        terminalAction { try $0.openToolchainUpgradeInTerminal(formulas: names) }
        brewOutdated = []
    }

    var menuBarSummary: MenuBarSummary {
        MenuBarSummary(
            anyInstanceRunning: instances.contains(where: \.isRunning),
            runningContainers: groups.reduce(0) { $0 + $1.runningCount },
            // Disk warnings count too — everything the Attention card shows.
            hasProblems: groups.contains { $0.containers.contains(where: \.hasProblem) }
                || !diskWarnings.isEmpty
        )
    }

    var visibleGroups: [ContainerGroup] {
        var result = groups
        if !showStoppedContainers {
            result = result.compactMap { group in
                let running = group.containers.filter(\.isRunning)
                guard !running.isEmpty else { return nil }
                return ContainerGroup(project: group.project, containers: running, qualifier: group.qualifier)
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.compactMap { group in
                let matches = group.containers.filter { container in
                    container.displayName.localizedCaseInsensitiveContains(query)
                        || container.name.localizedCaseInsensitiveContains(query)
                        || container.image.localizedCaseInsensitiveContains(query)
                        || (container.composeProject?.localizedCaseInsensitiveContains(query) ?? false)
                }
                guard !matches.isEmpty else { return nil }
                return ContainerGroup(project: group.project, containers: matches, qualifier: group.qualifier)
            }
        }
        return result
    }

    // MARK: - Polling

    func startPolling() {
        refreshNow()
        restartPollTimer()
    }

    /// Background heartbeat when the panel is closed.
    private static let backgroundInterval: TimeInterval = 60

    private func restartPollTimer() {
        pollTimer?.invalidate()
        let chosen = TimeInterval(max(refreshInterval, 5))
        let interval = panelVisible ? chosen : max(chosen, Self.backgroundInterval)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollTick()
            }
        }
    }

    func panelDidOpen() {
        guard !panelVisible else { return }
        panelVisible = true
        refreshNow()
        revalidateToolchainIfNeeded()
        restartPollTimer()
    }

    func panelDidClose() {
        guard panelVisible else { return }
        panelVisible = false
        restartPollTimer()
    }

    private func pollTick() {
        // Paused while any start/stop is in flight — the eventual completion
        // triggers its own refresh.
        guard actionsInFlight == 0 else { return }
        refreshNow()
    }

    func refreshNow() {
        appLog.notice("refreshNow (task in flight: \(self.refreshTask != nil))")
        guard refreshTask == nil else { return }
        let service = self.service
        refreshTask = Task { [weak self] in
            // List calls block on subprocesses, so hop off the main actor.
            let outcome = await Task.detached(priority: .utility) { () -> RefreshOutcome in
                var outcome = RefreshOutcome()
                do {
                    outcome.instances = try service.listInstances()
                } catch {
                    outcome.instanceError = error
                }
                do {
                    outcome.containers = try service.listContainers()
                } catch {
                    outcome.containerError = error
                }
                return outcome
            }.value
            self?.apply(outcome)
            self?.refreshTask = nil
        }
    }

    private struct RefreshOutcome: Sendable {
        var instances: [ColimaInstance] = []
        var containers: [DockerContainer] = []
        var instanceError: Error?
        var containerError: Error?
    }

    private func apply(_ outcome: RefreshOutcome) {
        appLog.notice("refresh outcome: instances=\(outcome.instances.count) containers=\(outcome.containers.count) instanceError=\(outcome.instanceError.map { String(describing: $0) } ?? "none", privacy: .public) containerError=\(outcome.containerError.map { String(describing: $0) } ?? "none", privacy: .public)")
        hasLoadedOnce = true

        if let error = outcome.instanceError {
            if case ColimaServiceError.colimaNotInstalled = error {
                colimaInstalled = false
            } else {
                lastError = error.localizedDescription
            }
            instances = []
        } else {
            colimaInstalled = true
            instances = outcome.instances
            lastError = nil
        }

        if let error = outcome.containerError {
            switch error {
            case ColimaServiceError.dockerNotInstalled:
                dockerInstalled = false
                dockerUnreachable = true
                groups = []
            case ColimaServiceError.dockerUnreachable:
                // Expected whenever the VM is stopped or still booting; show
                // an empty container list rather than an error banner.
                dockerInstalled = true
                dockerUnreachable = true
                groups = []
            default:
                dockerUnreachable = false
                groups = []
                if lastError == nil { lastError = error.localizedDescription }
            }
            statsByID = [:]
        } else {
            dockerInstalled = true
            dockerUnreachable = false
            groups = ContainerGroup.group(outcome.containers)
            refreshStats(for: outcome.containers)
            refreshDiskUsage()
            refreshVersions(for: outcome.containers)
            notifyUnexpectedTransitions(outcome.containers)
            previousContainers = Dictionary(outcome.containers.map { ($0.id, $0) }) { first, _ in first }
        }

        autoStartIfWanted()
        syncDomains()
    }

    // MARK: - Local .test domains

    private var desiredHostsBlock: String {
        HostsFile.renderBlock(hosts: customHosts.map(\.host))
    }

    func hostMapping(for container: DockerContainer) -> CustomHostMapping? {
        customHosts.first { $0.containerKey == container.stableKey }
    }

    /// Create or replace the mapping for one container, then apply it
    /// (hosts write → one admin prompt).
    func setHostMapping(for container: DockerContainer, host: String, port: Int) {
        customHosts.removeAll {
            $0.containerKey == container.stableKey || $0.host == host
        }
        customHosts.append(CustomHostMapping(host: host, containerKey: container.stableKey, port: port))
        persistCustomHosts()
        syncDomains()
        applyHostsFile()
    }

    func removeHostMapping(for container: DockerContainer) {
        guard hostMapping(for: container) != nil else { return }
        customHosts.removeAll { $0.containerKey == container.stableKey }
        persistCustomHosts()
        syncDomains()
        applyHostsFile()
    }

    /// Removal from the Settings overview, where only the hostname is known.
    func removeHostMapping(host: String) {
        guard customHosts.contains(where: { $0.host == host }) else { return }
        customHosts.removeAll { $0.host == host }
        persistCustomHosts()
        syncDomains()
        applyHostsFile()
    }

    private func persistCustomHosts() {
        if let data = try? JSONEncoder().encode(customHosts) {
            UserDefaults.standard.set(data, forKey: "customHostsJSON")
        }
    }

    /// Keep the proxy's routes matching the user's mappings. Hosts-file
    /// writes and CA trust are user-triggered (admin prompt); everything
    /// else here is silent.
    private func syncDomains() {
        guard localDomainsEnabled else {
            hostsOutOfSync = false
            if proxyRunning || httpsRunning {
                proxy.stopAll()
                proxyRunning = false
                httpsRunning = false
            }
            return
        }

        proxy.updateRoutes(
            Dictionary(customHosts.map { ($0.host, $0.port) }) { first, _ in first }
        )

        if !proxyRunning {
            do {
                try proxy.startHTTP(port: 80)
                proxyRunning = true
            } catch {
                lastError = "Local domains: couldn't listen on port 80 — \(error.localizedDescription)"
            }
        }
        if httpsEnabled {
            startOrRefreshHTTPS()
        } else if httpsRunning {
            proxy.stopHTTPS()
            httpsRunning = false
        }

        hostsOutOfSync = !domainService.hostsInSync(block: desiredHostsBlock)
    }

    /// (Re)issue the certificate when the host list changed, then serve TLS.
    private func startOrRefreshHTTPS() {
        let hosts = customHosts.map(\.host).sorted()
        guard !hosts.isEmpty else { return }
        guard !httpsRunning || hosts != issuedCertHosts else { return }
        let domainService = self.domainService
        Task { [weak self] in
            do {
                let identity = try await Task.detached(priority: .utility) {
                    try domainService.issueLeaf(hosts: hosts)
                }.value
                guard let self else { return }
                try self.proxy.startHTTPS(port: 443, identity: identity)
                self.httpsRunning = true
                self.issuedCertHosts = hosts
                appLog.notice("https listener up for \(hosts.count) hosts")
            } catch {
                appLog.notice("https start failed: \(String(describing: error), privacy: .public)")
                self?.lastError = "HTTPS: \(error.localizedDescription)"
                self?.httpsRunning = false
            }
        }
    }

    /// Write the managed block into /etc/hosts — one admin password prompt.
    func applyHostsFile() {
        let block = desiredHostsBlock
        let domainService = self.domainService
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try domainService.writeHostsBlock(block)
                }.value
                self?.hostsOutOfSync = false
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func setLocalDomains(_ enabled: Bool) {
        localDomainsEnabled = enabled
        if !enabled {
            // Also offer to clean /etc/hosts: an empty block removes ours.
            let domainService = self.domainService
            Task { [weak self] in
                try? await Task.detached { try domainService.writeHostsBlock("") }.value
                self?.hostsOutOfSync = false
            }
        }
        syncDomains()
        if enabled { applyHostsFile() }
    }

    func setHTTPS(_ enabled: Bool) {
        httpsEnabled = enabled
        guard enabled else {
            syncDomains()
            return
        }
        let domainService = self.domainService
        Task { [weak self] in
            do {
                // macOS shows its own trust-settings dialog on first enable.
                try await Task.detached(priority: .userInitiated) {
                    if !domainService.caIsTrusted() {
                        try domainService.trustCA()
                    }
                }.value
                self?.syncDomains()
            } catch {
                self?.lastError = error.localizedDescription
                self?.httpsEnabled = false
            }
        }
    }

    /// Domain-aware browser URL for a published port: the user's mapping
    /// when one covers this port, plain localhost otherwise.
    func webURL(for container: DockerContainer, port: Int) -> URL? {
        if localDomainsEnabled, let mapping = hostMapping(for: container), mapping.port == port {
            return URL(string: "\(httpsEnabled ? "https" : "http")://\(mapping.host)")
        }
        return URL(string: "http://localhost:\(port)")
    }

    // MARK: - Auto-start

    /// Optionally bring Colima up when the app launches. Once per launch, and
    /// only when nothing is running and no action is already in flight.
    private func autoStartIfWanted() {
        guard !didAttemptAutoStart, !instances.isEmpty else { return }
        didAttemptAutoStart = true
        guard
            autoStartColima,
            actionsInFlight == 0,
            !instances.contains(where: \.isRunning)
        else { return }
        let target = instances.first(where: { $0.name == "default" }) ?? instances[0]
        appLog.notice("auto-starting colima instance \(target.name, privacy: .public)")
        startInstance(target)
    }

    // MARK: - Crash notifications

    /// VM-level actions (stop/restart/reconfigure) take every container down
    /// with them — all expected, none notification-worthy.
    private func suppressAllContainerNotifications() {
        for group in groups {
            for container in group.containers {
                suppressNotificationIDs.insert(container.id)
            }
        }
    }

    /// Notify when a container stops or turns unhealthy without the user
    /// having acted through Colibar.
    private func notifyUnexpectedTransitions(_ containers: [DockerContainer]) {
        defer {
            // A refresh with no actions in flight means pending expected
            // stops have been observed; stop suppressing them.
            if actionsInFlight == 0 { suppressNotificationIDs.removeAll() }
        }
        guard notifyOnCrash, !previousContainers.isEmpty else { return }
        guard actionsInFlight == 0 else { return }
        for container in containers {
            guard
                let previous = previousContainers[container.id],
                !suppressNotificationIDs.contains(container.id)
            else { continue }
            if previous.isRunning && !container.isRunning {
                postNotification(
                    title: "\(container.displayName) stopped",
                    body: notificationBody(container)
                )
            } else if container.isUnhealthy && !previous.isUnhealthy {
                postNotification(
                    title: "\(container.displayName) is unhealthy",
                    body: notificationBody(container)
                )
            }
        }
    }

    private func notificationBody(_ container: DockerContainer) -> String {
        var body = container.status
        if let project = container.composeProject {
            body = "\(project) · \(body)"
        }
        return body
    }

    /// UNUserNotificationCenter throws an Objective-C exception when the
    /// process isn't a real .app bundle (e.g. `swift run`), so gate on that.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func requestNotificationAuthorization() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            appLog.notice("notification authorization granted=\(granted)")
        }
    }

    private func postNotification(title: String, body: String) {
        appLog.notice("notify: \(title, privacy: .public) — \(body, privacy: .public)")
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Summed usage across a set of containers, for group headers and the
    /// instance row. CPU% is docker's per-core convention (100% = one core
    /// fully busy), so totals can exceed 100 on multi-core VMs — same as top.
    struct UsageSummary {
        var cpuPercent: Double
        var memBytes: Int64
        var memLimitBytes: Int64?

        var label: String {
            var parts = [String(format: "CPU %.1f%%", cpuPercent)]
            if let memLimitBytes {
                parts.append("MEM \(ByteSize.format(memBytes)) / \(ByteSize.format(memLimitBytes))")
            } else {
                parts.append("MEM \(ByteSize.format(memBytes))")
            }
            return parts.joined(separator: " · ")
        }

        /// Group-header variant: no VM-total denominator.
        var compactLabel: String {
            String(format: "CPU %.1f%% · MEM %@", cpuPercent, ByteSize.format(memBytes))
        }
    }

    func usageSummary(for containers: [DockerContainer]) -> UsageSummary? {
        var summary = UsageSummary(cpuPercent: 0, memBytes: 0, memLimitBytes: nil)
        var sampled = false
        for container in containers {
            guard let stats = statsByID[container.id] else { continue }
            sampled = true
            summary.cpuPercent += stats.cpuPercent ?? 0
            summary.memBytes += stats.memBytes ?? 0
            summary.memLimitBytes = summary.memLimitBytes ?? stats.memLimitBytes
        }
        return sampled ? summary : nil
    }

    /// Total across every container — effectively what the Colima VM's
    /// workload is doing right now.
    var overallUsage: UsageSummary? {
        usageSummary(for: groups.flatMap(\.containers))
    }

    /// One-click disk cleanup: unused images + build cache only. Pauses
    /// polling while it runs (it can take a minute on a full disk), then
    /// re-measures the disk immediately so the warning updates.
    func pruneDisk() {
        guard !pruning else { return }
        pruning = true
        actionsInFlight += 1
        let service = self.service
        Task { [weak self] in
            var summary: String?
            var failure: String?
            do {
                summary = try await Task.detached(priority: .userInitiated) {
                    try service.pruneUnusedImages()
                }.value
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.pruning = false
            self.actionsInFlight -= 1
            if let failure {
                self.lastError = failure
            } else if let summary {
                self.statusMessage = summary
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    self?.statusMessage = nil
                }
            }
            self.lastDiskCheck = .distantPast // re-measure right away
            self.refreshNow()
        }
    }

    /// Probe runtime versions for running containers not yet asked, one
    /// container at a time in the background. Only while the panel is open.
    private func refreshVersions(for containers: [DockerContainer]) {
        guard panelVisible, versionsTask == nil else { return }
        let pending = containers.filter { $0.isRunning && !probedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        pending.forEach { probedIDs.insert($0.id) }
        let batch = pending.map { (id: $0.id, image: $0.image, service: $0.composeService) }
        let service = self.service
        versionsTask = Task { [weak self] in
            let results = await Task.detached(priority: .utility) { () -> [String: String] in
                var found: [String: String] = [:]
                for item in batch {
                    if let versions = service.probeVersions(
                        containerID: item.id, image: item.image, service: item.service
                    ) {
                        found[item.id] = versions
                    }
                }
                return found
            }.value
            guard let self else { return }
            appLog.notice("version probes: \(batch.count) containers, \(results.count) answered")
            self.versionsByID.merge(results) { _, new in new }
            self.versionsTask = nil
        }
    }

    /// Check VM disk fill occasionally while someone's looking.
    private func refreshDiskUsage() {
        guard panelVisible, diskTask == nil else { return }
        guard Date().timeIntervalSince(lastDiskCheck) > 120 else { return }
        let running = instances.filter(\.isRunning).map(\.name)
        guard !running.isEmpty else {
            diskUsage = [:]
            return
        }
        lastDiskCheck = Date()
        let service = self.service
        diskTask = Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { () -> [String: Int] in
                var result: [String: Int] = [:]
                for name in running {
                    if let percent = try? service.diskUsagePercent(instance: name) {
                        result[name] = percent
                    }
                }
                return result
            }.value
            guard let self else { return }
            if !usage.isEmpty { self.diskUsage = usage }
            self.diskTask = nil
        }
    }

    /// Sample usage for running containers. Never blocks the list refresh;
    /// at most one sample in flight, stale values persist until replaced.
    private func refreshStats(for containers: [DockerContainer]) {
        // Stats are display-only; skip the expensive sample when nobody's looking.
        guard panelVisible, statsTask == nil else { return }
        guard containers.contains(where: \.isRunning) else {
            statsByID = [:]
            return
        }
        let service = self.service
        statsTask = Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                (try? service.listContainerStats()) ?? []
            }.value
            guard let self else { return }
            appLog.notice("stats sample: \(stats.count) containers")
            if !stats.isEmpty {
                self.statsByID = Dictionary(stats.map { ($0.id, $0) }) { first, _ in first }
            }
            self.statsTask = nil
        }
    }

    // MARK: - Actions

    private func performAction(
        _ work: @escaping @Sendable () throws -> Void,
        markBusy: @escaping (AppState) -> Void,
        clearBusy: @escaping (AppState) -> Void
    ) {
        markBusy(self)
        actionsInFlight += 1
        Task { [weak self] in
            var failure: String?
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.actionsInFlight -= 1
            clearBusy(self)
            if let failure { self.lastError = failure }
            self.refreshNow()
        }
    }

    func startInstance(_ instance: ColimaInstance) {
        instanceAction(instance) { try $0.startInstance($1) }
    }

    func stopInstance(_ instance: ColimaInstance) {
        instanceAction(instance) { try $0.stopInstance($1) }
    }

    func restartInstance(_ instance: ColimaInstance) {
        instanceAction(instance) { try $0.restartInstance($1) }
    }

    private func instanceAction(
        _ instance: ColimaInstance,
        _ verb: @escaping @Sendable (ColimaService, String) throws -> Void
    ) {
        let service = self.service
        let name = instance.name
        suppressAllContainerNotifications()
        performAction(
            { try verb(service, name) },
            markBusy: { $0.busyInstances.insert(name) },
            clearBusy: { $0.busyInstances.remove(name) }
        )
    }

    /// Apply new resources to an instance: stop (if running) then start with
    /// --cpus/--memory/--disk. This restarts the VM, so it goes through the
    /// same busy/pause machinery as start/stop.
    func applyInstanceConfig(_ instance: ColimaInstance, cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let service = self.service
        let name = instance.name
        let wasRunning = instance.isRunning
        suppressAllContainerNotifications()
        performAction(
            {
                try service.applyInstanceConfig(
                    name: name, cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB,
                    stopFirst: wasRunning
                )
            },
            markBusy: { $0.busyInstances.insert(name) },
            clearBusy: { $0.busyInstances.remove(name) }
        )
    }

    func startContainer(_ container: DockerContainer) {
        containerAction([container.id]) { try $0.startContainers($1) }
    }

    func stopContainer(_ container: DockerContainer) {
        containerAction([container.id]) { try $0.stopContainers($1) }
    }

    func restartContainer(_ container: DockerContainer) {
        containerAction([container.id]) { try $0.restartContainers($1) }
    }

    private func containerAction(
        _ ids: [String],
        _ verb: @escaping @Sendable (ColimaService, [String]) throws -> Void
    ) {
        let service = self.service
        ids.forEach { suppressNotificationIDs.insert($0) }
        performAction(
            { try verb(service, ids) },
            markBusy: { state in ids.forEach { state.busyContainers.insert($0) } },
            clearBusy: { state in ids.forEach { state.busyContainers.remove($0) } }
        )
    }

    func startGroup(_ group: ContainerGroup) {
        groupAction(group, ids: group.containers.filter { !$0.isRunning }.map(\.id)) {
            try $0.startContainers($1)
        }
    }

    func stopGroup(_ group: ContainerGroup) {
        groupAction(group, ids: group.containers.filter(\.isRunning).map(\.id)) {
            try $0.stopContainers($1)
        }
    }

    func restartGroup(_ group: ContainerGroup) {
        groupAction(group, ids: group.containers.filter(\.isRunning).map(\.id)) {
            try $0.restartContainers($1)
        }
    }

    private func groupAction(
        _ group: ContainerGroup,
        ids: [String],
        _ verb: @escaping @Sendable (ColimaService, [String]) throws -> Void
    ) {
        guard !ids.isEmpty else { return }
        let service = self.service
        let groupID = group.id
        ids.forEach { suppressNotificationIDs.insert($0) }
        performAction(
            { try verb(service, ids) },
            markBusy: { state in
                state.busyGroups.insert(groupID)
                ids.forEach { state.busyContainers.insert($0) }
            },
            clearBusy: { state in
                state.busyGroups.remove(groupID)
                ids.forEach { state.busyContainers.remove($0) }
            }
        )
    }

    // MARK: - Terminal handoff & clipboard

    func openLogs(_ container: DockerContainer) {
        terminalAction { try $0.openLogsInTerminal(containerID: container.id) }
    }

    func openShell(_ container: DockerContainer) {
        terminalAction { try $0.openShellInTerminal(containerID: container.id) }
    }

    func openProjectTerminal(_ group: ContainerGroup) {
        guard let dir = group.workingDir else { return }
        terminalAction { try $0.openTerminal(atPath: dir) }
    }

    func openProjectLogs(_ group: ContainerGroup) {
        guard let dir = group.workingDir else { return }
        terminalAction { try $0.openProjectLogsInTerminal(workingDir: dir) }
    }

    /// VS Code, if installed — resolved once per launch.
    static let vsCodeURL: URL? =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    func openProjectInEditor(_ group: ContainerGroup) {
        guard let dir = group.workingDir, let editor = Self.vsCodeURL else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: dir, isDirectory: true)],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func openInBrowser(_ container: DockerContainer, port: Int) {
        guard let url = webURL(for: container, port: port) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMappedHost(_ mapping: CustomHostMapping) {
        guard let url = URL(string: "\(httpsEnabled ? "https" : "http")://\(mapping.host)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func terminalAction(_ work: @escaping @Sendable (ColimaService) throws -> Void) {
        let service = self.service
        Task { [weak self] in
            do {
                try await Task.detached { try work(service) }.value
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Settings actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastError = "Launch at login: \(error.localizedDescription)"
        }
    }

    func rescanBinaries() {
        service.rescanBinaries()
        colimaInstalled = true
        dockerInstalled = true
        lastError = nil
        refreshNow()
    }

    func toggleExpanded(_ group: ContainerGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }
}
