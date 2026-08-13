// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Colibar",
    platforms: [.macOS(.v14)],
    targets: [
        // Core layer: process running + CLI parsing. No UI imports allowed here.
        .target(name: "ColibarCore", path: "Sources/ColibarCore"),
        // The menu bar app.
        .executableTarget(
            name: "Colibar",
            dependencies: ["ColibarCore"],
            path: "Sources/Colibar",
            resources: [.copy("Resources/MenuBarMark.png")]
        ),
        // Throwaway verification CLI: prints parsed instances/containers.
        .executableTarget(
            name: "colibar-cli",
            dependencies: ["ColibarCore"],
            path: "Sources/colibar-cli"
        ),
        // Parser test suite as a plain executable: Command Line Tools ship
        // neither XCTest nor Swift Testing. Run with `swift run colibar-tests`.
        .executableTarget(
            name: "colibar-tests",
            dependencies: ["ColibarCore"],
            path: "Sources/colibar-tests"
        ),
    ]
)
