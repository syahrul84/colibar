import ColibarCore
import Foundation

// Minimal test harness: Command Line Tools ship neither XCTest nor Swift
// Testing, so the suite is a plain executable. `swift run colibar-tests`
// exits non-zero on any failure. Every fixture is a (possibly trimmed) real
// output captured from the machine this app was built against — if colima or
// docker change their formats, these fail before the menu bar does.

var failures = 0

func expect(_ condition: Bool, _ label: String, line: Int = #line) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label) (line \(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ label: String, line: Int = #line) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label): got \(String(describing: actual)), expected \(String(describing: expected)) (line \(line))")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n== \(name) ==")
    body()
}

func makeContainer(
    _ name: String, project: String? = nil, service: String? = nil, ports: [Int] = []
) -> DockerContainer {
    DockerContainer(
        id: name, name: name, image: "", state: "running", status: "Up",
        hostPorts: ports, sizeRaw: nil, health: nil, composeProject: project,
        composeService: service, composeWorkingDir: nil
    )
}

// MARK: - Instances

suite("colima instance parsing") {
    let json = """
    {"name":"default","status":"Running","arch":"aarch64","cpus":4,"memory":12884901888,"disk":107374182400,"runtime":"docker"}
    time="..." level=warning msg="some log line that must be skipped"
    """
    let instances = ColimaService.parseInstancesJSON(json)
    expectEqual(instances.count, 1, "one instance parsed, warning line skipped")
    expectEqual(instances.first?.name, "default", "name")
    expectEqual(instances.first?.status, .running, "status")
    expectEqual(instances.first?.memoryBytes, 12_884_901_888, "memory bytes")
    expectEqual(instances.first?.specsDescription, "4 CPU · 12 GiB · docker", "specs line")

    let table = """
    PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK      RUNTIME    ADDRESS
    default    Running    aarch64    4       12GiB     100GiB    docker
    work       Stopped    aarch64    8       16GiB     60GiB     docker
    """
    let fallback = ColimaService.parseInstancesTable(table)
    expectEqual(fallback.count, 2, "table fallback rows")
    expectEqual(fallback.first?.memoryBytes, 12 << 30, "table memory 12GiB")
    expectEqual(fallback.last?.status, .stopped, "table stopped status")
}

suite("byte sizes") {
    expectEqual(ByteSize.parse("12GiB"), 12 << 30, "12GiB")
    expectEqual(ByteSize.parse("512MiB"), 512 << 20, "512MiB")
    expectEqual(ByteSize.parse("239.3MiB"), Int64(239.3 * Double(1 << 20)), "fractional MiB")
    expectEqual(ByteSize.parse("1024"), 1024, "bare number")
    expectEqual(ByteSize.parse("banana"), nil, "garbage rejected")
}

// MARK: - Containers

suite("docker container parsing") {
    let line = #"{"ID":"ed274fa45fe77c21e0cc016692750e0925b1aa76539b91806d89b2968a83a3c3","Names":"frontend","Image":"imt-frontend:irems","State":"running","Status":"Up 4 days (unhealthy)","HealthStatus":"unhealthy","Size":"1.02MB (virtual 89.1MB)","Ports":"0.0.0.0:8095->80/tcp, [::]:8095->80/tcp","Labels":"com.docker.compose.project.config_files=/a/docker-compose.yaml,/b/override.yaml,com.docker.compose.project=docker,com.docker.compose.service=frontend,com.docker.compose.project.working_dir=/Users/x/proj"}"#
    let containers = ColimaService.parseContainersJSON(line)
    expectEqual(containers.count, 1, "one container parsed")
    if let container = containers.first {
        expectEqual(container.shortID, "ed274fa45fe7", "short id")
        expectEqual(container.displayName, "frontend", "compose service preferred as display name")
        expectEqual(container.hostPorts, [8095], "IPv6 duplicate port deduped")
        expectEqual(container.composeProject, "docker", "project label")
        expectEqual(container.composeWorkingDir, "/Users/x/proj", "working dir label")
        expectEqual(container.displaySize, "1.02MB", "writable-layer size")
        expect(container.isUnhealthy, "unhealthy detected")
        expect(container.hasProblem, "flagged as problem")
    }

    let labels = DockerContainer.parseLabels(
        "com.docker.compose.project.config_files=/a.yaml,/b.yaml,com.docker.compose.project=demo"
    )
    expectEqual(labels["com.docker.compose.project.config_files"], "/a.yaml,/b.yaml", "comma-containing value glued back")
    expectEqual(labels["com.docker.compose.project"], "demo", "following key intact")

    let healthNone = ColimaService.parseContainersJSON(#"{"ID":"abc","Names":"x","State":"running","HealthStatus":"none"}"#)
    expectEqual(healthNone.first?.health, nil, "HealthStatus none → nil")

    expectEqual(DockerContainer.parseHostPorts("0.0.0.0:8080-8090->8080-8090/tcp"), [8080], "port range takes first")
    expectEqual(DockerContainer.parseHostPorts("5000/tcp"), [], "unpublished port ignored")
}

suite("compose grouping") {
    let groups = ContainerGroup.group([
        makeContainer("loose"),
        makeContainer("v-web", project: "verdant", service: "web"),
        makeContainer("g-app", project: "goodbite", service: "app"),
        makeContainer("g-db", project: "goodbite", service: "db"),
    ])
    expectEqual(groups.map(\.title), ["goodbite", "verdant", "Other"], "projects alphabetical, Other last")
    expectEqual(groups.first?.containers.map(\.displayName), ["app", "db"], "services sorted within group")
}

// MARK: - Stats & disk

suite("docker stats parsing") {
    let line = #"{"BlockIO":"72.5MB / 23.1MB","CPUPerc":"0.15%","Container":"aac812d40d11b57225","ID":"aac812d40d11","MemPerc":"2.00%","MemUsage":"239.3MiB / 11.66GiB","Name":"worker","NetIO":"532MB / 236MB","PIDs":"5"}"#
    let stats = ColimaService.parseStatsJSON(line)
    expectEqual(stats.count, 1, "one sample parsed")
    expectEqual(stats.first?.cpuPercent, 0.15, "cpu percent")
    expectEqual(stats.first?.memUsage, "239.3MiB", "used memory string")
    expectEqual(stats.first?.memBytes, ByteSize.parse("239.3MiB"), "used memory bytes")
    expectEqual(stats.first?.memLimitBytes, ByteSize.parse("11.66GiB"), "limit = VM total")
    expectEqual(stats.first?.pids, 5, "pids")
}

suite("prune output parsing") {
    expectEqual(ColimaService.parseReclaimed("Deleted...\nTotal reclaimed space: 21.53GB"), "21.53GB", "reclaimed amount")
    expectEqual(ColimaService.parseReclaimed("Total reclaimed space: 0B"), nil, "0B treated as nothing")
    expectEqual(ColimaService.parseReclaimed("no such line"), nil, "missing line")
}

suite("VM disk usage parsing") {
    let df = """
    Filesystem            1024-blocks      Used Available Capacity Mounted on
    /dev/root                19221248   1631832  17573032       9% /
    tmpfs                     6110692         0   6110692       0% /dev/shm
    /dev/vdb1                61609772  54393884   4053880      94% /mnt/lima-colima
    """
    expectEqual(ColimaService.parseDiskUsePercent(df), 94, "prefers colima data disk over small root fs")

    let rootOnly = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/root 100 50 50 50% /
    """
    expectEqual(ColimaService.parseDiskUsePercent(rootOnly), 50, "falls back to /")
}

// MARK: - Local domains

suite("hostname normalization") {
    expectEqual(ProjectDomain.normalizeHostName("My App"), "my-app.test", "spaces to dashes + suffix")
    expectEqual(ProjectDomain.normalizeHostName("api.goodbite"), "api.goodbite.test", "subdomains kept")
    expectEqual(ProjectDomain.normalizeHostName("goodbite.test"), "goodbite.test", "existing suffix not doubled")
    expectEqual(ProjectDomain.normalizeHostName("https://shop.local/"), "shop.local.test", "URL pasted in, dots kept as subdomains")
    expectEqual(ProjectDomain.normalizeHostName("!!!"), nil, "garbage rejected")
}

suite("connection URLs") {
    func db(_ name: String, image: String, ports: [Int]) -> DockerContainer {
        DockerContainer(
            id: name, name: name, image: image, state: "running", status: "Up",
            hostPorts: ports, sizeRaw: nil, health: nil, composeProject: nil,
            composeService: name, composeWorkingDir: nil
        )
    }
    expectEqual(db("postgres", image: "postgres:16", ports: [5433]).connectionURL, "postgresql://localhost:5433", "postgres")
    expectEqual(db("cache", image: "redis:7-alpine", ports: [6380]).connectionURL, "redis://localhost:6380", "redis by image")
    expectEqual(db("db", image: "mariadb:11", ports: [3306]).connectionURL, "mysql://localhost:3306", "mariadb → mysql scheme")
    expectEqual(db("app", image: "php:8.3-fpm", ports: [9000]).connectionURL, nil, "non-database has none")
}

suite("web port heuristic") {
    expectEqual(ProjectDomain.webPort(for: makeContainer("mailpit", ports: [1025, 8025])), 8025, "mailpit UI beats SMTP")
    expectEqual(ProjectDomain.webPort(for: makeContainer("pg", ports: [5432])), 5432, "single port used as-is")
    expectEqual(ProjectDomain.webPort(for: makeContainer("vite", ports: [5173])), 5173, "dev server port recognized")
}

suite("hosts file block") {
    let block = HostsFile.renderBlock(hosts: ["goodbite.test"])
    let spliced = HostsFile.splice(into: "127.0.0.1 localhost\n", block: block)
    expect(spliced.contains("127.0.0.1 goodbite.test"), "IPv4 entry written")
    expect(spliced.contains("::1 goodbite.test"), "IPv6 entry written")
    expect(HostsFile.isInSync(content: spliced, block: block), "in sync after write")

    let newBlock = HostsFile.renderBlock(hosts: ["verdant.test"])
    let respliced = HostsFile.splice(into: spliced, block: newBlock)
    expect(!respliced.contains("goodbite.test"), "old block replaced")
    expect(respliced.contains("verdant.test"), "new block present")

    let cleaned = HostsFile.splice(into: respliced, block: "")
    expect(!cleaned.contains(HostsFile.beginMarker), "empty block removes ours")
    expect(cleaned.contains("127.0.0.1 localhost"), "unrelated lines preserved")
}

// MARK: - Reverse proxy

suite("proxy host header") {
    let head = "GET / HTTP/1.1\r\nHost: Goodbite.TEST:443\r\nAccept: */*\r\n\r\n"
    expectEqual(ReverseProxy.hostHeader(in: head), "goodbite.test", "lowercased, port stripped")
    expectEqual(ReverseProxy.hostHeader(in: "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n"), nil, "missing host")
}

suite("proxy header injection") {
    let head = "GET / HTTP/1.1\r\nHost: goodbite.test\r\nX-Forwarded-Proto: spoofed\r\nConnection: keep-alive\r\n\r\n"
    let rewritten = ReverseProxy.injectForwardHeaders(head, tls: true, host: "goodbite.test")
    expect(rewritten.contains("X-Forwarded-Proto: https"), "proto announced")
    expect(rewritten.contains("X-Forwarded-Port: 443"), "port announced")
    expect(rewritten.contains("Connection: close"), "connection forced closed")
    expect(!rewritten.contains("spoofed"), "inbound x-forwarded stripped")
    expect(!rewritten.contains("keep-alive"), "client connection header dropped")
    expect(rewritten.hasSuffix("\r\n\r\n"), "head terminator intact")

    let upgrade = "GET /app HTTP/1.1\r\nHost: reverb.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
    let tunneled = ReverseProxy.injectForwardHeaders(upgrade, tls: false, host: "reverb.test")
    expect(tunneled.contains("Connection: Upgrade"), "websocket upgrade preserved")
    expect(!tunneled.contains("Connection: close"), "no close on upgrade")
    expect(tunneled.contains("X-Forwarded-Proto: http"), "proto still announced")
}

suite("shell path resolution") {
    let shell = Shell()
    expectEqual(shell.resolve("definitely-not-a-real-binary-xyz"), nil, "missing binary resolves nil")
    // The miss must be cached: a repeat lookup may not fall through to the
    // login-shell probe (which costs hundreds of ms every poll otherwise).
    let start = Date()
    _ = shell.resolve("definitely-not-a-real-binary-xyz")
    let elapsed = Date().timeIntervalSince(start)
    expect(elapsed < 0.05, "second lookup served from miss cache (\(Int(elapsed * 1000))ms)")
    shell.clearPathCache()
    expectEqual(shell.resolve("ls"), "/bin/ls", "standard binary found by directory probe")
}

// MARK: - Summary

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) FAILURE(S)")
    exit(1)
}
