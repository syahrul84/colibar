import Foundation

/// One user-created hostname: "goodbite.test" → host port 8000. Containers
/// are identified by compose project/service (stable across recreations)
/// rather than container ID.
public struct CustomHostMapping: Codable, Equatable, Sendable, Identifiable {
    public let host: String
    public let containerKey: String
    public let port: Int

    public var id: String { host }

    public init(host: String, containerKey: String, port: Int) {
        self.host = host
        self.containerKey = containerKey
        self.port = port
    }
}

extension DockerContainer {
    /// Identity that survives `docker compose up` recreating the container.
    public var stableKey: String {
        if let composeProject {
            return "\(composeProject)/\(composeService ?? name)"
        }
        return name
    }
}

/// Pure logic for the .test domain feature: which hosts map to which ports,
/// and what the managed /etc/hosts block should contain. No I/O here.
public struct ProjectDomain: Equatable, Sendable {
    public let project: String
    /// e.g. "goodbite.test"
    public let host: String
    /// The port `host` itself routes to (the project's "web" service).
    public let primaryPort: Int
    /// service-name → (subdomain host, port) for every service with a port.
    public let serviceHosts: [ServiceHost]

    public struct ServiceHost: Equatable, Sendable {
        public let service: String
        public let host: String
        public let port: Int

        public init(service: String, host: String, port: Int) {
            self.service = service
            self.host = host
            self.port = port
        }
    }

    public init(project: String, host: String, primaryPort: Int, serviceHosts: [ServiceHost]) {
        self.project = project
        self.host = host
        self.primaryPort = primaryPort
        self.serviceHosts = serviceHosts
    }

    /// Services that usually are "the web app" in a compose stack, in
    /// preference order. Sail's default service is literally "laravel.test".
    static let webServiceNames = [
        "laravel.test", "app", "web", "nginx", "frontend", "webserver", "site", "backend",
    ]
    /// Ports that smell like HTTP when no service name matches.
    static let webPorts = [80, 443, 8080, 8000, 8025, 3000, 5173, 4200, 8100, 8888]
    /// Ports that are definitely not a browser destination (smtp, dbs, queues).
    static let nonWebPorts: Set<Int> = [25, 465, 587, 1025, 1125, 3306, 5432, 5433, 6379, 6380, 5672, 9000, 9501, 11211, 27017]

    /// Best port to point a browser at for one container.
    public static func webPort(for container: DockerContainer) -> Int? {
        let ports = container.hostPorts
        if let hit = ports.first(where: { webPorts.contains($0) }) { return hit }
        if let hit = ports.first(where: { !nonWebPorts.contains($0) }) { return hit }
        return ports.first
    }

    /// User input → valid .test hostname: "My App" → "my-app.test",
    /// "api.goodbite" → "api.goodbite.test", "goodbite.test" stays as is.
    /// Returns nil when nothing usable remains.
    public static func normalizeHostName(_ input: String) -> String? {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
        if text.hasSuffix(".test") { text = String(text.dropLast(5)) }
        let labels = text.split(separator: ".").map { hostLabel(String($0)) }.filter { $0 != "x" }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ".") + ".test"
    }

    /// DNS-safe label from a compose service name ("laravel.test" → "laravel-test").
    public static func hostLabel(_ name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "x" : collapsed
    }

    /// Build domains for every compose project that publishes at least one port.
    public static func build(from groups: [ContainerGroup]) -> [ProjectDomain] {
        groups.compactMap { group in
            guard let project = group.project else { return nil } // "Other" has no domain
            let projectLabel = hostLabel(project)
            let withPorts = group.containers.filter { !$0.hostPorts.isEmpty }
            guard !withPorts.isEmpty else { return nil }

            let serviceHosts: [ServiceHost] = withPorts.compactMap { container in
                guard let port = webPort(for: container) else { return nil }
                let service = container.composeService ?? container.name
                return ServiceHost(
                    service: service,
                    host: "\(hostLabel(service)).\(projectLabel).test",
                    port: port
                )
            }

            let primary = pickPrimary(withPorts)
            return ProjectDomain(
                project: project,
                host: "\(projectLabel).test",
                primaryPort: primary,
                serviceHosts: serviceHosts
            )
        }
    }

    static func pickPrimary(_ containers: [DockerContainer]) -> Int {
        for name in webServiceNames {
            if let match = containers.first(where: { ($0.composeService ?? $0.name) == name }),
               let port = webPort(for: match) {
                return port
            }
        }
        let allPorts = containers.flatMap(\.hostPorts)
        for candidate in webPorts where allPorts.contains(candidate) { return candidate }
        return allPorts.first(where: { !nonWebPorts.contains($0) }) ?? allPorts.min() ?? 80
    }

    /// All hostnames this domain owns.
    public var allHosts: [String] {
        [host] + serviceHosts.map(\.host)
    }
}

/// Renders and splices the managed block in /etc/hosts.
public enum HostsFile {
    public static let beginMarker = "# BEGIN COLIBAR - managed by Colibar.app, do not edit"
    public static let endMarker = "# END COLIBAR"

    public static func renderBlock(hosts: [String]) -> String {
        guard !hosts.isEmpty else { return "" }
        var lines = [beginMarker]
        // One line per host: easier to read and diff than a mega-line.
        for host in hosts {
            lines.append("127.0.0.1 \(host)")
            lines.append("::1 \(host)")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Replace (or append/remove) the managed block in existing content.
    public static func splice(into existing: String, block: String) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: beginMarker) {
            let end = lines[begin...].firstIndex(of: endMarker) ?? begin
            lines.removeSubrange(begin...min(end, lines.count - 1))
            // Drop a trailing blank left behind by removal.
            if begin < lines.count, begin > 0, lines[begin].isEmpty, lines[begin - 1].isEmpty {
                lines.remove(at: begin)
            }
        }
        var result = lines.joined(separator: "\n")
        if !block.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += block + "\n"
        }
        return result
    }

    /// Whether /etc/hosts content already contains exactly this block.
    public static func isInSync(content: String, block: String) -> Bool {
        if block.isEmpty { return !content.contains(beginMarker) }
        return content.contains(block)
    }
}
