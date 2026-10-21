// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PoddlePlayback",
    // macOS 26 rather than 27 so `swift test` and `poddle-render` run on Macs that are still on 26;
    // the 27-only AVFAudio calls are behind availability checks (see Compat.swift).
    platforms: [.iOS(.v27), .macOS(.v26)],
    products: [
        .library(name: "PoddlePlayback", targets: ["PoddlePlayback"]),
        .executable(name: "poddle-render", targets: ["poddle-render"]),
    ],
    targets: [
        .target(name: "PoddlePlayback"),
        .executableTarget(name: "poddle-render", dependencies: ["PoddlePlayback"]),
        .testTarget(name: "PoddlePlaybackTests", dependencies: ["PoddlePlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
