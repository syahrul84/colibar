import Foundation

// MARK: - Colima instances

public enum InstanceStatus: Equatable, Sendable {
    case running
    case stopped
    case other(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "running": self = .running
        case "stopped", "": self = .stopped
        default: self = .other(rawValue)
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .other(let raw): return raw
        }
    }
}

public struct ColimaInstance: Identifiable, Equatable, Sendable {
    public let name: String
    public let status: InstanceStatus
    public let arch: String?
    public let cpus: Int?
    public let memoryBytes: Int64?
    public let diskBytes: Int64?
    public let runtime: String?

    public var id: String { name }
    public var isRunning: Bool { status == .running }

    public init(
        name: String, status: InstanceStatus, arch: String?, cpus: Int?,
        memoryBytes: Int64?, diskBytes: Int64?, runtime: String?
    ) {
        self.name = name
        self.status = status
        self.arch = arch
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.runtime = runtime
    }

    /// e.g. "4 CPU · 12 GiB · docker"
    public var specsDescription: String {
        var parts: [String] = []
        if let cpus { parts.append("\(cpus) CPU") }
        if let memoryBytes { parts.append(Self.formatBytes(memoryBytes)) }
        if let runtime { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 1 {
            return gib == gib.rounded()
                ? "\(Int(gib)) GiB"
                : String(format: "%.1f GiB", gib)
        }
        let mib = Double(bytes) / Double(1 << 20)
        return "\(Int(mib.rounded())) MiB"
    }
}

// MARK: - Docker containers

public struct DockerContainer: Identifiable, Equatable, Sendable {
    /// Full (untruncated) container ID.
    public let id: String
    public let name: String
    public let image: String
    /// Raw docker state: running, exited, created, paused, restarting, dead.
    public let state: String
    /// Human status line, e.g. "Up 4 days (healthy)".
    public let status: String
    /// Unique published host ports, in the order docker reports them.
    public let hostPorts: [Int]
    /// docker's Size field, e.g. "2.69MB (virtual 654MB)"; writable layer first.
    public let sizeRaw: String?
    /// docker's HealthStatus: healthy / unhealthy / starting; nil if no healthcheck.
    public let health: String?
    public let composeProject: String?
    public let composeService: String?
    /// com.docker.compose.project.working_dir — where the compose file lives.
    public let composeWorkingDir: String?

    public var shortID: String { String(id.prefix(12)) }
    public var isRunning: Bool { state == "running" }
    /// States that are neither cleanly running nor cleanly stopped.
    public var isTransitional: Bool { state == "restarting" || state == "paused" || state == "created" }
    public var isUnhealthy: Bool { isRunning && health == "unhealthy" }
    /// Anything a user should worry about: failing healthcheck, restart loop, dead.
    public var hasProblem: Bool { isUnhealthy || state == "restarting" || state == "dead" }

    /// Connection URL for well-known database/cache images, built from the
    /// first published port — for pasting into TablePlus and friends.
    public var connectionURL: String? {
        guard let port = hostPorts.first else { return nil }
        let haystack = "\(image.lowercased()) \(composeService?.lowercased() ?? name.lowercased())"
        let schemes: [(needle: String, scheme: String)] = [
            ("postgres", "postgresql"), ("pgsql", "postgresql"),
            ("mysql", "mysql"), ("mariadb", "mysql"),
            ("redis", "redis"), ("valkey", "redis"),
            ("mongo", "mongodb"),
            ("memcached", "memcached"),
        ]
        for (needle, scheme) in schemes where haystack.contains(needle) {
            return "\(scheme)://localhost:\(port)"
        }
        return nil
    }

    /// Version hint from the image tag alone: "node:12" → "node 12",
    /// "postgres:16.3-alpine" → "postgres 16.3". Nil for non-numeric tags
    /// like custom builds ("imt-backend:irems") — exec probes cover those.
    public var tagVersion: String? {
        guard let colon = image.lastIndex(of: ":") else { return nil }
        let tag = image[image.index(after: colon)...]
        guard let first = tag.first, first.isNumber, !tag.contains("/") else { return nil }
        guard let name = image[..<colon].split(separator: "/").last else { return nil }
        let version = tag.split(separator: "-").first.map(String.init) ?? String(tag)
        return "\(name) \(version)"
    }

    /// Human phrasing of hasProblem, for the panel's attention list.
    public var problemReason: String? {
        if state == "restarting" { return "Restart looping" }
        if isUnhealthy { return "Failing health check" }
        if state == "dead" { return "Dead — needs removal or restart" }
        return nil
    }
    /// Compose service name reads better than "project-service-1".
    public var displayName: String { composeService ?? name }
    /// Writable-layer size without the "(virtual …)" suffix.
    public var displaySize: String? {
        guard let sizeRaw, !sizeRaw.isEmpty else { return nil }
        return sizeRaw.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public init(
        id: String, name: String, image: String, state: String, status: String,
        hostPorts: [Int], sizeRaw: String?, health: String?, composeProject: String?,
        composeService: String?, composeWorkingDir: String?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.hostPorts = hostPorts
        self.sizeRaw = sizeRaw
        self.health = health
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeWorkingDir = composeWorkingDir
    }

    /// Parse docker's `Labels` field ("key=value,key=value"). Label values in
    /// practice can contain commas (e.g. compose config_files lists), so split
    /// on commas but only accept segments containing "=" as new pairs,
    /// gluing comma-containing values back together.
    public static func parseLabels(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        var labels: [String: String] = [:]
        var currentKey: String?
        for segment in raw.split(separator: ",", omittingEmptySubsequences: false) {
            if let equals = segment.firstIndex(of: "=") {
                let key = String(segment[..<equals])
                currentKey = key
                labels[key] = String(segment[segment.index(after: equals)...])
            } else if let key = currentKey {
                labels[key]! += "," + String(segment)
            }
        }
        return labels
    }

    /// Extract unique host ports from docker's `Ports` string, e.g.
    /// "0.0.0.0:8082->8080/tcp, [::]:8082->8080/tcp" → [8082].
    /// IPv4 and IPv6 bindings repeat the same host port, hence the dedupe.
    public static func parseHostPorts(_ raw: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for mapping in raw.split(separator: ",") {
            guard let arrow = mapping.range(of: "->") else { continue }
            let bindSide = mapping[..<arrow.lowerBound]
            guard let colon = bindSide.lastIndex(of: ":") else { continue }
            let portText = bindSide[bindSide.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Port ranges like "8080-8090" — take the first port.
            let firstPort = portText.split(separator: "-").first.map(String.init) ?? portText
            if let port = Int(firstPort), seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }
}

// MARK: - Toolchain updates

/// One outdated Homebrew formula: "docker 29.6.0 → 29.7.1".
public struct BrewOutdatedItem: Equatable, Sendable {
    public let name: String
    public let installed: String
    public let latest: String

    public init(name: String, installed: String, latest: String) {
        self.name = name
        self.installed = installed
        self.latest = latest
    }
}

// MARK: - App updates

public enum AppUpdate {
    /// Semantic-ish comparison: "v1.7.0" vs "1.6.2" → true. Missing
    /// components count as zero, so "1.7" > "1.6.2".
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func components(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let remoteParts = components(remote)
        let localParts = components(local)
        for index in 0..<max(remoteParts.count, localParts.count) {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let l = index < localParts.count ? localParts[index] : 0
            if r != l { return r > l }
        }
        return false
    }
}

// MARK: - Byte sizes

public enum ByteSize {
    /// "239.3MiB", "11.66GiB", "1.5MB", "512" → bytes. Decimal suffixes are
    /// treated as binary; close enough for display purposes.
    public static func parse(_ text: String) -> Int64? {
        let units: [(String, Int64)] = [
            ("GIB", 1 << 30), ("MIB", 1 << 20), ("KIB", 1 << 10),
            ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1),
        ]
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        for (suffix, multiplier) in units where upper.hasSuffix(suffix) {
            if let value = Double(upper.dropLast(suffix.count)) {
                return Int64(value * Double(multiplier))
            }
        }
        return Int64(upper)
    }

    /// 1234567890 → "1.1 GiB"
    public static func format(_ bytes: Int64) -> String {
        ColimaInstance.formatBytes(bytes)
    }
}

// MARK: - Container stats

/// One sample from `docker stats --no-stream` for a running container.
public struct ContainerStats: Identifiable, Equatable, Sendable {
    /// Full container ID (docker stats' Container field).
    public let id: String
    public let cpuPercent: Double?
    /// e.g. "239.3MiB" — the used side of MemUsage.
    public let memUsage: String?
    /// Parsed sides of MemUsage ("used / limit"); the limit is the VM total.
    public let memBytes: Int64?
    public let memLimitBytes: Int64?
    public let memPercent: Double?
    /// e.g. "532MB / 236MB" (rx / tx).
    public let netIO: String?
    /// e.g. "72.5MB / 23.1MB" (read / write).
    public let blockIO: String?
    public let pids: Int?

    public init(
        id: String, cpuPercent: Double?, memUsage: String?, memBytes: Int64?,
        memLimitBytes: Int64?, memPercent: Double?, netIO: String?,
        blockIO: String?, pids: Int?
    ) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.memUsage = memUsage
        self.memBytes = memBytes
        self.memLimitBytes = memLimitBytes
        self.memPercent = memPercent
        self.netIO = netIO
        self.blockIO = blockIO
        self.pids = pids
    }

    /// "0.15%" → 0.15
    public static func parsePercent(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }

    /// "239.3MiB / 11.66GiB" → "239.3MiB"
    public static func parseUsedMemory(_ text: String?) -> String? {
        guard let text else { return nil }
        let used = text.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (used?.isEmpty ?? true) ? nil : used
    }
}

// MARK: - Compose grouping

public struct ContainerGroup: Identifiable, Equatable, Sendable {
    /// Compose project name; nil for containers outside any project.
    public let project: String?
    public var containers: [DockerContainer]
    /// Set when two stacks share a project name (compose defaults the name
    /// to the directory holding the compose file, so every repo with a
    /// `docker/` folder collides on "docker"). Usually the parent folder.
    public let qualifier: String?

    public init(project: String?, containers: [DockerContainer], qualifier: String? = nil) {
        self.project = project
        self.containers = containers
        self.qualifier = qualifier
    }

    /// Same-named projects from different directories must not share
    /// identity (collapse state, busy tracking), hence the dir in the id.
    public var id: String { (project ?? "\u{FFFF}other") + "|" + (workingDir ?? "") }
    public var title: String {
        guard let project else { return "Other" }
        return qualifier.map { "\(project) · \($0)" } ?? project
    }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var isFullyRunning: Bool { runningCount == containers.count && !containers.isEmpty }
    /// The compose project directory, when docker recorded one.
    public var workingDir: String? { containers.compactMap(\.composeWorkingDir).first }

    /// Group containers by compose project AND compose working directory —
    /// docker's project label alone is ambiguous (see `qualifier`). Groups
    /// sort by title, the "Other" group always last; within a group, rows
    /// sort by display name so Sail stacks read app/mysql/redis consistently.
    public static func group(_ containers: [DockerContainer]) -> [ContainerGroup] {
        struct Key: Hashable {
            let project: String
            let workingDir: String?
        }
        var byKey: [Key: [DockerContainer]] = [:]
        var loose: [DockerContainer] = []
        for container in containers {
            if let project = container.composeProject {
                byKey[Key(project: project, workingDir: container.composeWorkingDir), default: []]
                    .append(container)
            } else {
                loose.append(container)
            }
        }

        func sorted(_ list: [DockerContainer]) -> [DockerContainer] {
            list.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        var nameCounts: [String: Int] = [:]
        for key in byKey.keys { nameCounts[key.project, default: 0] += 1 }

        var groups = byKey.map { key, members in
            ContainerGroup(
                project: key.project,
                containers: sorted(members),
                qualifier: nameCounts[key.project, default: 0] > 1
                    ? Self.directoryQualifier(key.workingDir, project: key.project)
                    : nil
            )
        }
        groups.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !loose.isEmpty {
            groups.append(ContainerGroup(project: nil, containers: sorted(loose)))
        }
        return groups
    }

    /// Human tag telling colliding projects apart: the nearest path
    /// component that isn't just the project name again.
    /// "/Users/x/irems-sg/docker" (project "docker") → "irems-sg".
    public static func directoryQualifier(_ workingDir: String?, project: String) -> String? {
        guard let workingDir else { return nil }
        let components = workingDir.split(separator: "/").map(String.init)
        for component in components.reversed() where component.lowercased() != project.lowercased() {
            return component
        }
        return components.last
    }
}
