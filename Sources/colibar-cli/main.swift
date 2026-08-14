import ColibarCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer so piped/backgrounded output arrives live

// Throwaway verification CLI for the core layer. Prints resolved binary
// paths, parsed instances, and parsed containers grouped by compose project.

let shell = Shell.shared
let service = ColimaService(shell: shell)

// Action subcommands used to verify the write paths during development:
//   colibar-cli start-container <id> | stop-container <id> | restart-container <id>
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2 {
    do {
        switch arguments[0] {
        case "start-container": try service.startContainers([arguments[1]])
        case "stop-container": try service.stopContainers([arguments[1]])
        case "restart-container": try service.restartContainers([arguments[1]])
        default:
            print("unknown subcommand: \(arguments[0])")
            exit(2)
        }
        print("OK")
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

// Dev verification for the .test domain stack: prints the computed mapping
// and hosts block, then serves the reverse proxy on high ports until killed.
//   colibar-cli domains-test <httpPort> <httpsPort>
if arguments.count >= 3, arguments[0] == "domains-test",
   let httpPort = UInt16(arguments[1]), let httpsPort = UInt16(arguments[2]) {
    do {
        let containers = try service.listContainers()
        let domains = ProjectDomain.build(from: ContainerGroup.group(containers))
        var routes: [String: Int] = [:]
        // Optional extra routes for testing: "host=port host=port ..."
        for extra in arguments.dropFirst(3) {
            let parts = extra.split(separator: "=")
            if parts.count == 2, let port = Int(parts[1]) {
                routes[String(parts[0])] = port
            }
        }
        for domain in domains {
            routes[domain.host] = domain.primaryPort
            print("\(domain.host) -> \(domain.primaryPort)")
            for serviceHost in domain.serviceHosts {
                routes[serviceHost.host] = serviceHost.port
                print("\(serviceHost.host) -> \(serviceHost.port)")
            }
        }
        print("--- hosts block ---")
        print(HostsFile.renderBlock(hosts: domains.flatMap(\.allHosts)))
        let domainService = DomainService(shell: shell)
        let identity = try domainService.issueLeaf(hosts: domains.flatMap(\.allHosts))
        print("--- ca: \(domainService.caCertificatePath)")
        let proxy = ReverseProxy()
        proxy.updateRoutes(routes)
        try proxy.startHTTP(port: httpPort)
        try proxy.startHTTPS(port: httpsPort, identity: identity)
        print("READY http=\(httpPort) https=\(httpsPort)")
        dispatchMain()
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

// Probe runtime versions of every running container (dev verification).
if arguments.count == 1, arguments[0] == "probe-versions" {
    do {
        for container in try service.listContainers() where container.isRunning {
            let versions = service.probeVersions(
                containerID: container.id, image: container.image, service: container.composeService
            )
            print("\(container.displayName) [\(container.image)]: \(versions ?? "-")")
        }
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

print("== Binary resolution ==")
for binary in ["colima", "docker"] {
    print("  \(binary): \(shell.resolve(binary) ?? "NOT FOUND")")
}

print("\n== Colima instances ==")
do {
    let instances = try service.listInstances()
    if instances.isEmpty { print("  (no instances)") }
    for instance in instances {
        print("  \(instance.name) [\(instance.status.label)] \(instance.specsDescription) arch=\(instance.arch ?? "?")")
    }
} catch {
    print("  ERROR: \(error.localizedDescription)")
}

print("\n== Containers ==")
do {
    let containers = try service.listContainers()
    let groups = ContainerGroup.group(containers)
    if groups.isEmpty { print("  (no containers)") }
    for group in groups {
        print("  [\(group.title)] \(group.runningCount)/\(group.containers.count) running")
        for container in group.containers {
            let ports = container.hostPorts.isEmpty
                ? ""
                : " ports=" + container.hostPorts.map(String.init).joined(separator: ",")
            let size = container.displaySize.map { " size=\($0)" } ?? ""
            print("    \(container.isRunning ? "●" : "○") \(container.displayName) (\(container.name)) id=\(container.shortID)\(ports)\(size) — \(container.status)")
        }
    }
} catch {
    print("  ERROR: \(error.localizedDescription)")
}

print("\n== Stats (one sample) ==")
do {
    for stats in try service.listContainerStats() {
        let cpu = stats.cpuPercent.map { String(format: "%.2f%%", $0) } ?? "?"
        let mem = stats.memUsage ?? "?"
        print("  \(String(stats.id.prefix(12))) cpu=\(cpu) mem=\(mem) pids=\(stats.pids.map(String.init) ?? "?")")
    }
} catch {
    print("  ERROR: \(error.localizedDescription)")
}
