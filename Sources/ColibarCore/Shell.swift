import Foundation

/// Result of running an external process to completion.
public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum ShellError: Error, LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "'\(name)' not found in \(Shell.searchDirectories.joined(separator: ", ")) or the login shell PATH."
        case .launchFailed(let path, let message):
            return "Failed to launch \(path): \(message)"
        }
    }
}

/// Runs external processes and resolves binary paths. Knows nothing about
/// colima or docker specifically.
///
/// Apps launched from Finder inherit a minimal PATH (no Homebrew), so
/// `colima`/`docker` are invisible to `Process` unless we search their usual
/// install directories ourselves. A login-shell `command -v` lookup is the
/// fallback of last resort — it costs hundreds of milliseconds, far too slow
/// for a poll loop — so every resolution is cached until `clearPathCache()`.
public final class Shell: @unchecked Sendable {
    public static let shared = Shell()

    public static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    private let cacheLock = NSLock()
    private var pathCache: [String: String] = [:]
    /// Binaries already searched for and not found. Cached so a poll loop
    /// with colima/docker missing doesn't spawn a login shell every tick —
    /// the settings "Re-scan" (clearPathCache) is the way to look again.
    private var missCache: Set<String> = []

    public init() {}

    // MARK: - Path resolution

    /// Absolute path for `binary`, or nil if it cannot be found anywhere.
    public func resolve(_ binary: String) -> String? {
        cacheLock.lock()
        if let cached = pathCache[binary] {
            cacheLock.unlock()
            return cached
        }
        if missCache.contains(binary) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        var found: String?
        let fileManager = FileManager.default
        for directory in Self.searchDirectories {
            let candidate = directory + "/" + binary
            if fileManager.isExecutableFile(atPath: candidate) {
                found = candidate
                break
            }
        }
        if found == nil {
            found = loginShellLookup(binary)
        }
        cacheLock.lock()
        if let found {
            pathCache[binary] = found
        } else {
            missCache.insert(binary)
        }
        cacheLock.unlock()
        return found
    }

    /// Forget every cached path (hits and misses) so the next `resolve`
    /// searches from scratch.
    public func clearPathCache() {
        cacheLock.lock()
        pathCache.removeAll()
        missCache.removeAll()
        cacheLock.unlock()
    }

    /// `$SHELL -lc "command -v <binary>"` — slow, only used when the direct
    /// directory scan misses (e.g. colima installed via a version manager).
    private func loginShellLookup(_ binary: String) -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }
        guard
            let result = try? runExecutable(at: shellPath, ["-lc", "command -v -- '\(binary)'"], timeout: 10),
            result.succeeded
        else { return nil }
        let path = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: - Process running

    /// Resolve `binary` and run it to completion.
    public func run(_ binary: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> ShellResult {
        guard let path = resolve(binary) else { throw ShellError.binaryNotFound(binary) }
        return try runExecutable(at: path, arguments, timeout: timeout)
    }

    /// Run an executable at a known absolute path.
    ///
    /// stdout and stderr are drained on concurrent queues while we wait —
    /// reading them sequentially after `waitUntilExit()` deadlocks as soon as
    /// the process writes more than one pipe buffer (~64 KB), which `docker ps
    /// -a --no-trunc` does easily. A watchdog SIGTERMs the process at
    /// `timeout`, escalating to SIGKILL if it ignores that.
    public func runExecutable(at path: String, _ arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        // Child processes (e.g. docker invoking credential helpers) need a
        // sane PATH too, not just the parent binary.
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = (Self.searchDirectories + [inheritedPath]).joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(path: path, message: error.localizedDescription)
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "colibar.shell.drain", attributes: .concurrent)
        drainGroup.enter()
        drainQueue.async {
            stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        let timedOutBox = FlagBox()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOutBox.value = true
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        drainGroup.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
            stderr: String(data: stderrBox.value, encoding: .utf8) ?? "",
            timedOut: timedOutBox.value
        )
    }
}

/// Lock-guarded mutable boxes so the drain queues and watchdog can write
/// from their own threads without data races.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
