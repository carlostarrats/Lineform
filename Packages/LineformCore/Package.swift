// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LineformCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "LineformCore", targets: ["LineformCore"]),
        .library(name: "LineformCoreTestSupport", targets: ["LineformCoreTestSupport"]),
    ],
    targets: [
        .target(
            name: "LineformCore",
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
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
