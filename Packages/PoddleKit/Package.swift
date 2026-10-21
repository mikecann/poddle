// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PoddleKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "PoddleKit", targets: ["PoddleKit"]),
    ],
    targets: [
        .target(name: "PoddleKit"),
        .testTarget(name: "PoddleKitTests", dependencies: ["PoddleKit"]),
    ],
    swiftLanguageModes: [.v6]
)
