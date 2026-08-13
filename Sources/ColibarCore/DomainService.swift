import Foundation
import Security

public enum DomainServiceError: Error, LocalizedError, Sendable {
    case opensslFailed(String)
    case identityImportFailed(OSStatus)
    case hostsWriteFailed(String)
    case userCancelled
    case trustFailed(String)

    public var errorDescription: String? {
        switch self {
        case .opensslFailed(let message): return "Certificate generation failed: \(message)"
        case .identityImportFailed(let status): return "Could not load the TLS identity (OSStatus \(status))."
        case .hostsWriteFailed(let message): return "Updating /etc/hosts failed: \(message)"
        case .userCancelled: return "Cancelled — approval is required for this step."
        case .trustFailed(let message):
            return "Trusting the certificate failed (\(message)). Manual route: open Keychain Access, find “Colibar Local CA” under login → Certificates, and set Trust → Always Trust."
        }
    }
}

/// The privileged/system side of local domains: the /etc/hosts managed block
/// and the local certificate authority. Certificates are generated with the
/// system's own openssl; the two operations that genuinely need admin rights
/// (writing /etc/hosts, trusting the CA) run through osascript so macOS shows
/// its standard password prompt to the user.
public struct DomainService: Sendable {
    private let shell: Shell
    public let stateDirectory: URL

    public init(shell: Shell = .shared) {
        self.shell = shell
        stateDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Colibar/tls", isDirectory: true)
    }

    // MARK: - /etc/hosts

    public func currentHostsContent() -> String {
        (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
    }

    public func hostsInSync(block: String) -> Bool {
        HostsFile.isInSync(content: currentHostsContent(), block: block)
    }

    /// Replace the managed block. Triggers one macOS admin-password prompt.
    public func writeHostsBlock(_ block: String) throws {
        let updated = HostsFile.splice(into: currentHostsContent(), block: block)
        let staging = stateDirectory.appendingPathComponent("hosts.staged")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try updated.write(to: staging, atomically: true, encoding: .utf8)

        // Single privileged step: install the staged file and flush DNS caches.
        let command = "cp '\(staging.path)' /etc/hosts && dscacheutil -flushcache && killall -HUP mDNSResponder"
        try runPrivileged(command, failure: { DomainServiceError.hostsWriteFailed($0) })
    }

    // MARK: - Certificate authority

    public var caCertificatePath: String { stateDirectory.appendingPathComponent("colibar-ca.crt").path }
    private var caKeyPath: String { stateDirectory.appendingPathComponent("colibar-ca.key").path }
    private var leafCertPath: String { stateDirectory.appendingPathComponent("leaf.crt").path }
    private var leafKeyPath: String { stateDirectory.appendingPathComponent("leaf.key").path }
    private var leafP12Path: String { stateDirectory.appendingPathComponent("leaf.p12").path }
    private static let p12Passphrase = "colibar-local"

    public var caExists: Bool { FileManager.default.fileExists(atPath: caCertificatePath) }

    /// Create the CA once; ~/Library/Application Support/Colibar/tls holds it.
    public func ensureCA() throws {
        guard !caExists else { return }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", caKeyPath, "-out", caCertificatePath,
            "-days", "3650",
            "-subj", "/CN=Colibar Local CA/O=Colibar",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        ])
    }

    /// Mark the CA trusted for TLS. One-time; afterwards every cert the CA
    /// signs is green-padlock valid.
    ///
    /// Deliberately user-domain (login keychain), not system: macOS 15+
    /// refuses programmatic system-trust changes even as root. The user-
    /// domain call makes macOS itself show its "Certificate Trust Settings"
    /// confirmation dialog, which is the supported path.
    public func trustCA() throws {
        try ensureCA()
        let loginKeychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        // -p ssl is load-bearing: without a policy restriction the CA is
        // trusted for EVERYTHING, including code signing — which drags it
        // into Gatekeeper's launch assessments and can stall every app
        // launch on the machine. SSL-only is all https://*.test needs.
        // Blocks while macOS shows its trust dialog, hence the long timeout.
        let result = try shell.runExecutable(
            at: "/usr/bin/security",
            ["add-trusted-cert", "-p", "ssl", "-r", "trustRoot", "-k", loginKeychain, caCertificatePath],
            timeout: 300
        )
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut || stderr.localizedCaseInsensitiveContains("cancel") {
                throw DomainServiceError.userCancelled
            }
            throw DomainServiceError.trustFailed(stderr.isEmpty ? "exit \(result.exitCode)" : stderr)
        }
    }

    public func caIsTrusted() -> Bool {
        guard caExists else { return false }
        let result = try? shell.runExecutable(
            at: "/usr/bin/security",
            ["verify-cert", "-c", caCertificatePath, "-p", "ssl"],
            timeout: 10
        )
        return result?.succeeded ?? false
    }

    /// (Re)issue the server certificate covering every current host, signed
    /// by the CA. Silent — no admin needed. Apple caps TLS leaf validity at
    /// 825 days; 398 keeps a wide margin, and re-issue is automatic anyway.
    public func issueLeaf(hosts: [String]) throws -> SecIdentity {
        try ensureCA()
        let sanList = hosts.map { "DNS:\($0)" }.joined(separator: ",")
        let extFile = stateDirectory.appendingPathComponent("leaf.ext")
        try """
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(sanList)
        """.write(to: extFile, atomically: true, encoding: .utf8)

        let csrPath = stateDirectory.appendingPathComponent("leaf.csr").path
        try openssl([
            "req", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", leafKeyPath, "-out", csrPath,
            "-subj", "/CN=Colibar Local/O=Colibar",
        ])
        try openssl([
            "x509", "-req", "-in", csrPath, "-sha256",
            "-CA", caCertificatePath, "-CAkey", caKeyPath, "-CAcreateserial",
            "-out", leafCertPath, "-days", "398",
            "-extfile", extFile.path,
        ])
        try openssl([
            "pkcs12", "-export",
            "-inkey", leafKeyPath, "-in", leafCertPath,
            "-out", leafP12Path,
            "-passout", "pass:\(Self.p12Passphrase)",
        ])
        return try loadIdentity()
    }

    public func loadIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: URL(fileURLWithPath: leafP12Path))
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: Self.p12Passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard
            status == errSecSuccess,
            let first = (items as? [[String: Any]])?.first,
            let identityRef = first[kSecImportItemIdentity as String]
        else { throw DomainServiceError.identityImportFailed(status) }
        return identityRef as! SecIdentity
    }

    // MARK: - Helpers

    private func openssl(_ arguments: [String]) throws {
        let result = try shell.runExecutable(at: "/usr/bin/openssl", arguments, timeout: 60)
        guard result.succeeded else {
            throw DomainServiceError.opensslFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Run one shell command with admin rights via the standard macOS
    /// password dialog. The command string must not contain double quotes.
    private func runPrivileged(_ command: String, failure: (String) -> Error) throws {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = try shell.runExecutable(at: "/usr/bin/osascript", ["-e", script], timeout: 300)
        guard result.succeeded else {
            let stderr = result.stderr
            if stderr.contains("-128") { throw DomainServiceError.userCancelled }
            throw failure(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
