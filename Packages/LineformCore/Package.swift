// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LineformCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "LineformCore", targets: ["LineformCore"]),
    ],
    // Pinned exactly as the app pins them (Package.resolved): BeautifulMermaid brings elk-swift 1.0.2.
    // The Mermaid orientation fix in MermaidRendering.swift is coupled to this BeautifulMermaid pin.
    dependencies: [
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", exact: "1.0.4"),
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3"),
    ],
    targets: [
        .target(
            name: "LineformCore",
            dependencies: [
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // Test doubles for LineformCoreTests only. Deliberately not a product: linking it into
        // LineformTests makes Xcode build LineformCore as a dynamic framework, which breaks its
        // resource-bundle lookup. LineformTests compiles AITestDoubles.swift by file reference.
        .target(
            name: "LineformCoreTestSupport",
            dependencies: ["LineformCore"]
        ),
        .testTarget(
            name: "LineformCoreTests",
            dependencies: ["LineformCore", "LineformCoreTestSupport"],
            resources: [.copy("Fixtures/history-1.8.0"), .copy("Fixtures/render-corpus")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
