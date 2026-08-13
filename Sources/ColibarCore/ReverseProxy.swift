import Foundation
import Network
import Security

/// Host-header reverse proxy: routes goodbite.test → 127.0.0.1:<port>.
///
/// Reads just enough of each incoming connection to find the Host header,
/// dials the mapped local port, replays the buffered bytes, then relays raw
/// bytes both ways — so websockets, SSE, and keep-alive all pass through
/// untouched. The HTTPS listener terminates TLS with a local identity and
/// forwards plain HTTP to the container, mkcert/Valet style.
///
/// Modern macOS allows unprivileged binds to ports 80/443, so no root needed.
public final class ReverseProxy: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Int] = [:]
    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private let queue = DispatchQueue(label: "colibar.proxy", attributes: .concurrent)

    public init() {}

    // MARK: - Control

    /// host (lowercased) → target port.
    public func updateRoutes(_ newRoutes: [String: Int]) {
        lock.lock()
        routes = Dictionary(uniqueKeysWithValues: newRoutes.map { ($0.key.lowercased(), $0.value) })
        lock.unlock()
    }

    public func startHTTP(port: UInt16) throws {
        stopHTTP()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        configure(listener, tls: false)
        lock.lock()
        httpListener = listener
        lock.unlock()
    }

    public func startHTTPS(port: UInt16, identity: SecIdentity) throws {
        stopHTTPS()
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )
        let parameters = NWParameters(tls: tlsOptions)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        configure(listener, tls: true)
        lock.lock()
        httpsListener = listener
        lock.unlock()
    }

    public func stopHTTP() {
        lock.lock()
        httpListener?.cancel()
        httpListener = nil
        lock.unlock()
    }

    public func stopHTTPS() {
        lock.lock()
        httpsListener?.cancel()
        httpsListener = nil
        lock.unlock()
    }

    public func stopAll() {
        stopHTTP()
        stopHTTPS()
    }

    // MARK: - Connection handling

    private func configure(_ listener: NWListener, tls: Bool) {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.readRequestHead(connection, buffered: Data(), tls: tls)
        }
        listener.start(queue: queue)
    }

    /// Accumulate bytes until the end of the request headers, then route.
    private func readRequestHead(_ client: NWConnection, buffered: Data, tls: Bool) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else {
                client.cancel()
                return
            }
            var buffer = buffered
            buffer.append(data)
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.route(client, head: buffer, headerEnd: headerEnd.upperBound, tls: tls)
            } else if buffer.count > 128 * 1024 || isComplete {
                client.cancel() // header flood or truncated request
            } else {
                self.readRequestHead(client, buffered: buffer, tls: tls)
            }
        }
    }

    private func route(_ client: NWConnection, head: Data, headerEnd: Int, tls: Bool) {
        guard
            let headText = String(data: head.prefix(headerEnd), encoding: .utf8),
            let host = Self.hostHeader(in: headText)
        else {
            respondAndClose(client, status: "400 Bad Request", body: "Missing Host header.")
            return
        }
        // Tell the app what the browser actually requested, so frameworks
        // with trusted proxies generate https:// URLs (no mixed content).
        var rewrittenHead = Data(Self.injectForwardHeaders(headText, tls: tls, host: host).utf8)
        rewrittenHead.append(head.suffix(from: headerEnd)) // any body bytes already read
        let head = rewrittenHead
        lock.lock()
        let port = routes[host]
        lock.unlock()
        guard let port else {
            respondAndClose(
                client,
                status: "502 Bad Gateway",
                body: "Colibar has no route for \(host). Is the container running?"
            )
            return
        }

        let upstream = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                upstream.stateUpdateHandler = nil
                upstream.send(content: head, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        client.cancel()
                        upstream.cancel()
                        return
                    }
                    self.relay(from: client, to: upstream)
                    self.relay(from: upstream, to: client)
                })
            case .failed, .cancelled:
                self.respondAndClose(
                    client,
                    status: "502 Bad Gateway",
                    body: "\(host) maps to port \(port), but nothing answered there."
                )
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// One direction of the tunnel. The next receive is chained after the
    /// send completes, which gives natural backpressure.
    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil, !isComplete {
                        self.relay(from: source, to: destination)
                    } else {
                        source.cancel()
                        destination.cancel()
                    }
                })
            } else if isComplete || error != nil {
                source.cancel()
                destination.cancel()
            } else {
                self.relay(from: source, to: destination)
            }
        }
    }

    private func respondAndClose(_ connection: NWConnection, status: String, body: String) {
        let payload = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Add X-Forwarded-* headers (dropping any the client sent). Non-upgrade
    /// requests also get `Connection: close`, making each TCP connection a
    /// single request — that's what lets us inject headers per request
    /// without parsing bodies. Browsers just open parallel connections, and
    /// on loopback the keep-alive loss is unmeasurable. Websocket upgrades
    /// keep their Connection header and tunnel untouched.
    static func injectForwardHeaders(_ head: String, tls: Bool, host: String) -> String {
        var lines = head.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return head }

        let isUpgrade = lines.contains {
            let lower = $0.lowercased()
            return lower.hasPrefix("connection:") && lower.contains("upgrade")
        }
        var kept = [lines[0]]
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("x-forwarded-") { continue }
            if !isUpgrade, lower.hasPrefix("connection:") { continue }
            kept.append(line)
        }
        kept.append("X-Forwarded-Proto: \(tls ? "https" : "http")")
        kept.append("X-Forwarded-Host: \(host)")
        kept.append("X-Forwarded-Port: \(tls ? "443" : "80")")
        kept.append("X-Forwarded-For: 127.0.0.1")
        if !isUpgrade { kept.append("Connection: close") }
        return kept.joined(separator: "\r\n") + "\r\n\r\n"
    }

    static func hostHeader(in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "host" else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if let portColon = value.lastIndex(of: ":"), !value.hasSuffix("]") {
                value = String(value[..<portColon])
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
