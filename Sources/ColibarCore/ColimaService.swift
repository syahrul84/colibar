import Foundation

public enum ColimaServiceError: Error, LocalizedError, Sendable {
    case colimaNotInstalled
    case dockerNotInstalled
    case dockerUnreachable(String)
    case commandFailed(command: String, message: String)
    case commandTimedOut(command: String)

    public var errorDescription: String? {
        switch self {
        case .colimaNotInstalled:
            return "Colima is not installed. Install it with: brew install colima"
        case .dockerNotInstalled:
            return "The docker CLI is not installed. Install it with: brew install docker"
        case .dockerUnreachable(let message):
            return "Docker daemon unreachable: \(message)"
        case .commandFailed(let command, let message):
            return "\(command) failed: \(message)"
        case .commandTimedOut(let command):
            return "\(command) timed out"
        }
    }
}

/// Every colima/docker invocation and all output parsing lives here — if a
/// future Colima release changes its output format, this is the only file
/// that should need editing. Never touches UI; every method is safe to call
/// off the main thread (they block on subprocesses, so don't call them on it).
public struct ColimaService: Sendable {
    private let shell: Shell

    /// Cold VM boots are slow; colima start can legitimately take minutes.
    public static let instanceActionTimeout: TimeInterval = 600
    public static let containerActionTimeout: TimeInterval = 120
    public static let listTimeout: TimeInterval = 20

    public init(shell: Shell = .shared) {
        self.shell = shell
    }

    // MARK: - Binary discovery

    public var colimaInstalled: Bool { shell.resolve("colima") != nil }
    public var dockerInstalled: Bool { shell.resolve("docker") != nil }

    public func rescanBinaries() {
        shell.clearPathCache()
    }

    // MARK: - Instances

    public func listInstances() throws -> [ColimaInstance] {
        let result: ShellResult
        do {
            result = try shell.run("colima", ["list", "--json"], timeout: Self.listTimeout)
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.colimaNotInstalled
        }
        if result.timedOut { throw ColimaServiceError.commandTimedOut(command: "colima list") }

        if result.succeeded {
            let instances = Self.parseInstancesJSON(result.stdout)
            if !instances.isEmpty || result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return instances
            }
        }
        // Older colima builds have no --json flag; scrape the plain table.
        let fallback: ShellResult
        do {
            fallback = try shell.run("colima", ["list"], timeout: Self.listTimeout)
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.colimaNotInstalled
        }
        guard fallback.succeeded else {
            throw ColimaServiceError.commandFailed(
                command: "colima list",
                message: pickMessage(fallback)
            )
        }
        return Self.parseInstancesTable(fallback.stdout)
    }

    /// `colima list --json` emits JSON Lines: one object per instance with
    /// name, status, arch, cpus, memory, disk, runtime (memory/disk in bytes).
    private struct InstanceJSON: Decodable {
        let name: String
        let status: String?
        let arch: String?
        let cpus: Int?
        let memory: Int64?
        let disk: Int64?
        let runtime: String?
    }

    public static func parseInstancesJSON(_ output: String) -> [ColimaInstance] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line in
            guard
                let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                !data.isEmpty,
                let parsed = try? decoder.decode(InstanceJSON.self, from: data)
            else { return nil } // skip log/warning lines mixed into output
            return ColimaInstance(
                name: parsed.name,
                status: InstanceStatus(rawValue: parsed.status ?? ""),
                arch: parsed.arch,
                cpus: parsed.cpus,
                memoryBytes: parsed.memory,
                diskBytes: parsed.disk,
                runtime: parsed.runtime
            )
        }
    }

    /// Fallback for colima builds without --json. Table shape:
    /// PROFILE  STATUS  ARCH  CPUS  MEMORY  DISK  RUNTIME  ADDRESS
    public static func parseInstancesTable(_ output: String) -> [ColimaInstance] {
        let lines = output.split(separator: "\n").map(String.init)
        guard let header = lines.first, header.uppercased().contains("PROFILE") else { return [] }
        return lines.dropFirst().compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 2 else { return nil }
            func column(_ index: Int) -> String? { index < columns.count ? columns[index] : nil }
            return ColimaInstance(
                name: columns[0],
                status: InstanceStatus(rawValue: columns[1]),
                arch: column(2),
                cpus: column(3).flatMap(Int.init),
                memoryBytes: column(4).flatMap(Self.parseSizeString),
                diskBytes: column(5).flatMap(Self.parseSizeString),
                runtime: column(6)
            )
        }
    }

    /// "12GiB" / "100GiB" / "512MiB" → bytes.
    static func parseSizeString(_ text: String) -> Int64? {
        ByteSize.parse(text)
    }

    public func startInstance(_ name: String) throws {
        try runColimaAction(["start", "-p", name], timeout: Self.instanceActionTimeout)
    }

    public func stopInstance(_ name: String) throws {
        try runColimaAction(["stop", "-p", name], timeout: Self.instanceActionTimeout)
    }

    public func restartInstance(_ name: String) throws {
        try runColimaAction(["restart", "-p", name], timeout: Self.instanceActionTimeout)
    }

    /// (Re)start an instance with new resources. Colima only picks up
    /// --cpus/--memory/--disk on `start`, so a running instance must be
    /// stopped first; disk can grow but never shrink.
    public func applyInstanceConfig(
        name: String, cpus: Int, memoryGiB: Int, diskGiB: Int, stopFirst: Bool
    ) throws {
        if stopFirst {
            try runColimaAction(["stop", "-p", name], timeout: Self.instanceActionTimeout)
        }
        try runColimaAction(
            [
                "start", "-p", name,
                "--cpus", String(cpus),
                "--memory", String(memoryGiB),
                "--disk", String(diskGiB),
            ],
            timeout: Self.instanceActionTimeout
        )
    }

    private func runColimaAction(_ arguments: [String], timeout: TimeInterval) throws {
        let result: ShellResult
        do {
            result = try shell.run("colima", arguments, timeout: timeout)
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.colimaNotInstalled
        }
        let command = "colima " + arguments.joined(separator: " ")
        if result.timedOut { throw ColimaServiceError.commandTimedOut(command: command) }
        guard result.succeeded else {
            throw ColimaServiceError.commandFailed(command: command, message: pickMessage(result))
        }
    }

    // MARK: - Containers

    public func listContainers() throws -> [DockerContainer] {
        let result: ShellResult
        do {
            result = try shell.run(
                "docker",
                ["ps", "-a", "--no-trunc", "--format", "{{json .}}"],
                timeout: Self.listTimeout
            )
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.dockerNotInstalled
        }
        if result.timedOut { throw ColimaServiceError.commandTimedOut(command: "docker ps") }
        guard result.succeeded else {
            let message = pickMessage(result)
            if Self.looksLikeDaemonUnreachable(message) {
                throw ColimaServiceError.dockerUnreachable(message)
            }
            throw ColimaServiceError.commandFailed(command: "docker ps", message: message)
        }
        return Self.parseContainersJSON(result.stdout)
    }

    static func looksLikeDaemonUnreachable(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("cannot connect to the docker daemon")
            || lower.contains("docker daemon running")
            || lower.contains("connection refused")
            || lower.contains("no such file or directory") // stale unix socket
            || lower.contains("error during connect")
    }

    /// `docker ps --format '{{json .}}'` keys are capitalised.
    private struct ContainerJSON: Decodable {
        let ID: String
        let Names: String
        let Image: String?
        let State: String?
        let Status: String?
        let Ports: String?
        let Labels: String?
        let Size: String?
        let HealthStatus: String?
    }

    public static func parseContainersJSON(_ output: String) -> [DockerContainer] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line in
            guard
                let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                !data.isEmpty,
                let parsed = try? decoder.decode(ContainerJSON.self, from: data)
            else { return nil }
            let labels = DockerContainer.parseLabels(parsed.Labels ?? "")
            return DockerContainer(
                id: parsed.ID,
                // Multi-network containers can report comma-joined names.
                name: parsed.Names.split(separator: ",").first.map(String.init) ?? parsed.Names,
                image: parsed.Image ?? "",
                state: parsed.State ?? "",
                status: parsed.Status ?? "",
                hostPorts: DockerContainer.parseHostPorts(parsed.Ports ?? ""),
                sizeRaw: parsed.Size,
                health: parsed.HealthStatus.flatMap { $0 == "none" || $0.isEmpty ? nil : $0 },
                composeProject: labels["com.docker.compose.project"],
                composeService: labels["com.docker.compose.service"],
                composeWorkingDir: labels["com.docker.compose.project.working_dir"]
            )
        }
    }

    /// One usage sample per running container. `docker stats --no-stream`
    /// takes ~2s (it samples an interval to compute CPU%), so callers must
    /// never block list refreshes on it.
    public func listContainerStats() throws -> [ContainerStats] {
        let result: ShellResult
        do {
            result = try shell.run(
                "docker",
                ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"],
                timeout: 30
            )
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.dockerNotInstalled
        }
        if result.timedOut { throw ColimaServiceError.commandTimedOut(command: "docker stats") }
        guard result.succeeded else {
            let message = pickMessage(result)
            if Self.looksLikeDaemonUnreachable(message) {
                throw ColimaServiceError.dockerUnreachable(message)
            }
            throw ColimaServiceError.commandFailed(command: "docker stats", message: message)
        }
        return Self.parseStatsJSON(result.stdout)
    }

    private struct StatsJSON: Decodable {
        let Container: String
        let CPUPerc: String?
        let MemUsage: String?
        let MemPerc: String?
        let NetIO: String?
        let BlockIO: String?
        let PIDs: String?
    }

    public static func parseStatsJSON(_ output: String) -> [ContainerStats] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line in
            guard
                let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                !data.isEmpty,
                let parsed = try? decoder.decode(StatsJSON.self, from: data)
            else { return nil }
            let memParts = (parsed.MemUsage ?? "")
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let used = memParts.first(where: { !$0.isEmpty })
            let limit = memParts.count > 1 ? memParts[1] : nil
            return ContainerStats(
                id: parsed.Container,
                cpuPercent: ContainerStats.parsePercent(parsed.CPUPerc),
                memUsage: used,
                memBytes: used.flatMap(ByteSize.parse),
                memLimitBytes: limit.flatMap(ByteSize.parse),
                memPercent: ContainerStats.parsePercent(parsed.MemPerc),
                netIO: parsed.NetIO,
                blockIO: parsed.BlockIO,
                pids: parsed.PIDs.flatMap(Int.init)
            )
        }
    }

    public func startContainers(_ ids: [String]) throws {
        try runDockerAction("start", ids)
    }

    public func stopContainers(_ ids: [String]) throws {
        try runDockerAction("stop", ids)
    }

    public func restartContainers(_ ids: [String]) throws {
        try runDockerAction("restart", ids)
    }

    private func runDockerAction(_ verb: String, _ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let result: ShellResult
        do {
            result = try shell.run("docker", [verb] + ids, timeout: Self.containerActionTimeout)
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.dockerNotInstalled
        }
        let command = "docker \(verb)"
        if result.timedOut { throw ColimaServiceError.commandTimedOut(command: command) }
        guard result.succeeded else {
            let message = pickMessage(result)
            if Self.looksLikeDaemonUnreachable(message) {
                throw ColimaServiceError.dockerUnreachable(message)
            }
            throw ColimaServiceError.commandFailed(command: command, message: message)
        }
    }

    // MARK: - Disk cleanup

    /// Reclaim space from unused images and build cache. Deliberately NOT
    /// `docker system prune`: that deletes stopped containers, and stopped is
    /// a normal state for compose projects here. Containers, volumes, and
    /// networks are never touched. Returns a human summary like
    /// "Reclaimed 12.4GB (images) · 3.1GB (build cache)".
    public func pruneUnusedImages() throws -> String {
        var parts: [String] = []
        for (label, arguments) in [
            ("images", ["image", "prune", "-a", "-f"]),
            ("build cache", ["builder", "prune", "-a", "-f"]),
        ] {
            let result: ShellResult
            do {
                result = try shell.run("docker", arguments, timeout: 600)
            } catch ShellError.binaryNotFound {
                throw ColimaServiceError.dockerNotInstalled
            }
            if result.timedOut { throw ColimaServiceError.commandTimedOut(command: "docker \(arguments[0]) prune") }
            guard result.succeeded else {
                let message = pickMessage(result)
                if Self.looksLikeDaemonUnreachable(message) {
                    throw ColimaServiceError.dockerUnreachable(message)
                }
                throw ColimaServiceError.commandFailed(command: "docker \(arguments[0]) prune", message: message)
            }
            if let reclaimed = Self.parseReclaimed(result.stdout + result.stderr) {
                parts.append("\(reclaimed) (\(label))")
            }
        }
        return parts.isEmpty ? "Nothing to reclaim" : "Reclaimed " + parts.joined(separator: " · ")
    }

    /// "Total reclaimed space: 21.53GB" → "21.53GB"
    public static func parseReclaimed(_ output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            guard let range = line.range(of: "reclaimed space:") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !value.hasPrefix("0B") { return value }
        }
        return nil
    }

    // MARK: - VM disk usage

    /// Percent used of the VM disk that actually holds docker's images and
    /// volumes. Runs `df` inside the VM over colima ssh — a few hundred ms,
    /// so callers should poll it sparingly.
    public func diskUsagePercent(instance: String) throws -> Int? {
        let result: ShellResult
        do {
            result = try shell.run("colima", ["ssh", "-p", instance, "--", "df", "-kP"], timeout: 20)
        } catch ShellError.binaryNotFound {
            throw ColimaServiceError.colimaNotInstalled
        }
        guard result.succeeded else { return nil } // VM stopped or ssh not ready
        return Self.parseDiskUsePercent(result.stdout)
    }

    /// df -kP output: Filesystem 1024-blocks Used Available Capacity Mounted-on.
    /// Colima's data disk mounts at /mnt/lima-colima; docker data lives there
    /// (or under /var/lib/docker on older layouts), with / as last resort.
    static let dataMountCandidates = ["/mnt/lima-colima", "/var/lib/docker", "/"]

    public static func parseDiskUsePercent(_ output: String) -> Int? {
        var byMount: [String: Int] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 6 else { continue }
            let percent = Int(columns[4].trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            if let percent { byMount[String(columns[5])] = percent }
        }
        for mount in dataMountCandidates {
            if let percent = byMount[mount] { return percent }
        }
        return nil
    }

    // MARK: - Terminal handoff

    /// Follow a container's logs in Terminal.app. `docker logs -f` wants a
    /// real TTY for colors and Ctrl-C, hence osascript instead of a sheet.
    public func openLogsInTerminal(containerID: String) throws {
        guard let docker = shell.resolve("docker") else { throw ColimaServiceError.dockerNotInstalled }
        try runInTerminal("\(docker) logs --follow --tail 200 \(String(containerID.prefix(12)))")
    }

    /// Interactive shell inside the container; prefers bash, falls back to sh.
    public func openShellInTerminal(containerID: String) throws {
        guard let docker = shell.resolve("docker") else { throw ColimaServiceError.dockerNotInstalled }
        let short = String(containerID.prefix(12))
        try runInTerminal("\(docker) exec -it \(short) sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    /// Open a Terminal window cd'd into a directory (e.g. a compose project,
    /// ready for `sail artisan ...`).
    public func openTerminal(atPath path: String) throws {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        try runInTerminal("cd '\(escaped)'")
    }

    /// Follow every service's logs for a compose project, interleaved.
    public func openProjectLogsInTerminal(workingDir: String) throws {
        guard let docker = shell.resolve("docker") else { throw ColimaServiceError.dockerNotInstalled }
        let escaped = workingDir.replacingOccurrences(of: "'", with: "'\\''")
        try runInTerminal("cd '\(escaped)' && \(docker) compose logs --follow --tail 100")
    }

    private func runInTerminal(_ command: String) throws {
        // AppleScript string literal: escape backslashes, then quotes.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let result = try shell.runExecutable(at: "/usr/bin/osascript", ["-e", script], timeout: 15)
        guard result.succeeded else {
            throw ColimaServiceError.commandFailed(command: "osascript", message: pickMessage(result))
        }
    }

    private func pickMessage(_ result: ShellResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "exit code \(result.exitCode)" : stdout
    }
}
