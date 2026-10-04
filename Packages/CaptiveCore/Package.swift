// swift-tools-version: 6.0
// CaptiveCore: plattformneutrale Kernlogik von CaptiveAI (SPEC.md §4).
// Muss auf Linux mit `swift test` bauen. Apple-only-Code kommt später in ein eigenes Target `CaptiveCoreApple`.
import PackageDescription

let package = Package(
    name: "CaptiveCore",
    platforms: [
        // Alle verwendeten APIs gibt es ab iOS 26. Die App selbst zielt auf iOS 27 (SPEC §3.6).
        // Das Paket bleibt bei 26, damit die CI mit dem verfügbaren iOS-26-SDK bauen kann.
        .iOS("26.0"),
        .macOS("15.0"), // nur für `swift test` auf dem Mac-Host, kein Produkt-Target
    ],
    products: [
        .library(name: "CaptiveCore", targets: ["CaptiveCore"]),
        .library(name: "CaptiveCoreApple", targets: ["CaptiveCoreApple"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "CaptiveCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Resources/prl-v1.schema.json")]
        ),
        // Apple-only: Foundation Models, Keychain, URLSession-/Hotspot-Transport, WLAN-Konfiguration.
        // Alle Dateien sind per #if canImport geschützt. Unter Linux kompiliert das Target leer.
        .target(
            name: "CaptiveCoreApple",
            dependencies: ["CaptiveCore"]
        ),
        .testTarget(
            name: "CaptiveCoreTests",
            dependencies: ["CaptiveCore"]
            // Fixtures liegen in Tests/Fixtures und werden per #filePath geladen (kein Bundle nötig, Linux-tauglich).
        ),
    ]
)
