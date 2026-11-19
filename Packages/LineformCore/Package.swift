// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LineformCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "LineformCore", targets: ["LineformCore"]),
    ],
    targets: [
        .target(
            name: "LineformCore",
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
            resources: [.copy("Fixtures/history-1.8.0")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
