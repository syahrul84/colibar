import AppKit
import ColibarCore
import Foundation

/// External links and the update endpoint.
/// ⚠️ If the GitHub handle isn't `syahrul84`, this is the one place to fix.
enum AppLinks {
    static let kofi = URL(string: "https://ko-fi.com/syahrul84")!
    static let github = URL(string: "https://github.com/syahrul84/colibar")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/syahrul84/colibar/releases/latest")!
}

struct AvailableUpdate: Equatable {
    let version: String
    /// The release's Colibar .zip asset; nil if the release has none, in
    /// which case "install" just opens the release page.
    let zipURL: URL?
    let pageURL: URL
}

/// Checks GitHub Releases and installs updates. No Sparkle (no third-party
/// deps): download zip → strip quarantine → swap /Applications bundle →
/// relaunch. Quarantine stripping matters — an ad-hoc-signed download would
/// otherwise be refused by Gatekeeper.
@MainActor
final class UpdateManager: ObservableObject {
    @Published var checking = false
    @Published var installing = false
    /// Human outcome of the last manual check ("You're up to date", errors).
    @Published var status: String?
    @Published var available: AvailableUpdate?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private let shell = Shell.shared
    /// Called when a background check finds something, so AppState can notify.
    var onBackgroundUpdateFound: ((AvailableUpdate) -> Void)?

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// Daily background check, throttled via UserDefaults timestamp.
    func autoCheckIfDue() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        if manual { status = nil }
        Task { [weak self] in
            defer { self?.checking = false }
            guard let self else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            do {
                var request = URLRequest(url: AppLinks.releasesAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 404 {
                    if manual { self.status = "No releases published yet." }
                    return
                }
                guard http.statusCode == 200 else {
                    if manual { self.status = "GitHub answered \(http.statusCode) — try again later." }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard AppUpdate.isNewer(release.tag_name, than: self.currentVersion) else {
                    if manual { self.status = "You're on the latest version (v\(self.currentVersion))." }
                    return
                }
                let zip = release.assets.first { $0.name.hasSuffix(".zip") }
                let update = AvailableUpdate(
                    version: release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                    zipURL: zip.flatMap { URL(string: $0.browser_download_url) },
                    pageURL: URL(string: release.html_url) ?? AppLinks.github
                )
                self.available = update
                self.status = nil
                if !manual { self.onBackgroundUpdateFound?(update) }
            } catch {
                if manual { self.status = "Update check failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Download, swap the /Applications bundle, relaunch. Falls back to
    /// opening the release page when the release carries no zip asset.
    func install() {
        guard let update = available, !installing else { return }
        guard let zipURL = update.zipURL else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        installing = true
        let shell = self.shell
        Task { [weak self] in
            do {
                let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
                let bundlePath = try await Task.detached(priority: .userInitiated) { () -> String in
                    let workDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("colibar-update-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                    let unzip = try shell.runExecutable(
                        at: "/usr/bin/ditto",
                        ["-xk", downloaded.path, workDir.path],
                        timeout: 120
                    )
                    guard unzip.succeeded else { throw UpdateError.unpackFailed(unzip.stderr) }
                    guard
                        let appName = try FileManager.default
                            .contentsOfDirectory(atPath: workDir.path)
                            .first(where: { $0.hasSuffix(".app") })
                    else { throw UpdateError.noAppInArchive }
                    let newApp = workDir.appendingPathComponent(appName).path

                    // Downloaded = quarantined; strip it or Gatekeeper blocks
                    // the ad-hoc-signed bundle outright.
                    _ = try? shell.runExecutable(
                        at: "/usr/bin/xattr",
                        ["-rd", "com.apple.quarantine", newApp],
                        timeout: 30
                    )
                    let installed = "/Applications/Colibar.app"
                    try? FileManager.default.removeItem(atPath: installed)
                    let copy = try shell.runExecutable(
                        at: "/usr/bin/ditto", [newApp, installed], timeout: 120
                    )
                    guard copy.succeeded else { throw UpdateError.installFailed(copy.stderr) }
                    return installed
                }.value
                self?.relaunch(bundlePath: bundlePath)
            } catch {
                self?.installing = false
                self?.status = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    private func relaunch(bundlePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bundlePath + "/Contents/MacOS/Colibar")
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    enum UpdateError: Error, LocalizedError {
        case unpackFailed(String)
        case noAppInArchive
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .unpackFailed(let message): return "Couldn't unpack the download: \(message)"
            case .noAppInArchive: return "The release archive contains no .app bundle."
            case .installFailed(let message): return "Couldn't install to /Applications: \(message)"
            }
        }
    }
}
