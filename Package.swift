// swift-tools-version: 6.0
import PackageDescription

// Rack — system-wide audio control for macOS.
//
// Dependency arrows point downward only:
//
//   App  ->  AppCore  ->  AudioCore      (no UI frameworks)
//                     ->  DesignSystem   (no audio frameworks)
//
// The boundary rules are mechanically enforced by Scripts/check-boundaries.sh,
// which BoundaryCheckPlugin runs as a prebuild command on every `swift build`.

let package = Package(
    name: "Rack",
    // The process tap API (AudioHardwareCreateProcessTap, CATapDescription)
    // is macOS 14.2+, so the .v14 shorthand — which means 14.0 — is not
    // enough. The string form takes the real floor.
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Rack", targets: ["App"]),
        // `swift run RackTests`. Not a .testTarget: XCTest and swift-testing
        // both ship inside Xcode, and this package builds with Command Line
        // Tools alone. See Tests/RackTests/Check.swift.
        .executable(name: "RackTests", targets: ["RackTests"])
    ],
    targets: [
        // Wiring only. Owns @main, the scene graph, and nothing else.
        .executableTarget(
            name: "App",
            dependencies: ["AppCore"],
            plugins: ["BoundaryCheckPlugin"]
        ),

        // View models, app state, persistence, device policy.
        // The only module allowed to see both AudioCore and DesignSystem.
        .target(
            name: "AppCore",
            dependencies: ["AudioCore", "DesignSystem"]
        ),

        // Core Audio, DSP, realtime. Must never import SwiftUI or AppKit.
        .target(name: "AudioCore", dependencies: ["RackRealtime"]),

        // Things the audio thread needs that Swift cannot express: lock-free
        // atomics (Swift's own are macOS 15+, we target 14.4) and flush-to-zero
        // control. A support target beneath AudioCore, not a fifth peer —
        // nothing else may depend on it.
        .target(name: "RackRealtime"),

        // Theme protocol, tokens, skinned components. Must never import AudioCore.
        .target(name: "DesignSystem"),

        .plugin(name: "BoundaryCheckPlugin", capability: .buildTool()),
        .plugin(name: "TestRegistrationCheckPlugin", capability: .buildTool()),

        .executableTarget(
            name: "RackTests",
            dependencies: ["AudioCore", "AppCore", "DesignSystem"],
            path: "Tests/RackTests",
            // Generated screenshots, not source — see ThemeScreenshotTests.swift.
            exclude: ["ThemeScreenshots"],
            plugins: ["TestRegistrationCheckPlugin"]
        )
    ]
)
