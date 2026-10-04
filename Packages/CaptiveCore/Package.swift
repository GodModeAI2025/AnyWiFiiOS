// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptiveCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CaptiveCore", targets: ["CaptiveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "CaptiveCore",
            dependencies: ["SwiftSoup", "Yams"]
        ),
        .testTarget(
            name: "CaptiveCoreTests",
            dependencies: ["CaptiveCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
