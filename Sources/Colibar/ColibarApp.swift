import ColibarCore
import SwiftUI

@main
struct ColibarApp: App {
    @StateObject private var appState = AppState()

    init() {
        ScreenshotRenderer.renderIfRequested() // no-op without the CLI flag
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(summary: appState.menuBarSummary)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Colibar hexagon as a template image: macOS tints it to match the menu
/// bar (dark in light mode, white in dark mode), like every native icon.
///
/// Loaded asynchronously and published: Bundle.module's directory walk hits
/// the disk, and macOS can stall first-opens of a freshly re-signed bundle
/// (Gatekeeper assessment) — doing this lazily on the main thread once froze
/// the whole app at launch. Views show an SF Symbol until the mark arrives.
@MainActor
final class BrandMark: ObservableObject {
    static let shared = BrandMark()
    @Published private(set) var templateImage: NSImage?
    /// Red-tinted, non-template variant: template images are forced to
    /// monochrome by the menu bar, so the "needs attention" state ships its
    /// own color baked in.
    @Published private(set) var warningImage: NSImage?

    private init() {
        Task.detached(priority: .utility) {
            guard
                let url = Bundle.module.url(forResource: "MenuBarMark", withExtension: "png"),
                let image = NSImage(contentsOf: url)
            else { return }
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)

            let red = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.systemRed.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            red.isTemplate = false
            red.size = image.size

            await MainActor.run {
                BrandMark.shared.templateImage = image
                BrandMark.shared.warningImage = red
            }
        }
    }
}

/// The status item itself: icon reflects overall state, with a
/// running-container count when anything is up.
struct MenuBarLabel: View {
    let summary: MenuBarSummary
    @ObservedObject private var brand = BrandMark.shared

    var body: some View {
        // MenuBarExtra labels only render Image/Text; layout is handled by
        // the system, so keep this dumb. The mark turns red when anything
        // needs attention — unmissable on light and dark menu bars alike.
        if summary.hasProblems {
            if let warning = brand.warningImage {
                Image(nsImage: warning)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        } else {
            markImage
                .opacity(summary.anyInstanceRunning || summary.runningContainers > 0 ? 1 : 0.5)
        }
        if summary.runningContainers > 0 {
            Text("\(summary.runningContainers)")
        }
    }

    private var markImage: some View {
        Group {
            if let mark = brand.templateImage {
                Image(nsImage: mark)
            } else {
                Image(systemName: "shippingbox.fill")
            }
        }
    }
}
