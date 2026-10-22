// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PoddleKit",
    platforms: [.iOS("18.0"), .macOS("26.0")],
    products: [
        .library(name: "PoddleKit", targets: ["PoddleKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.1"),
    ],
    targets: [
        .target(
            name: "PoddleKit",
            dependencies: [.product(name: "ConvexMobile", package: "convex-swift")],
            // The App Store privacy manifest for what this package uses (UserDefaults).
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "PoddleKitTests", dependencies: ["PoddleKit"]),
    ],
    swiftLanguageModes: [.v6]
)
