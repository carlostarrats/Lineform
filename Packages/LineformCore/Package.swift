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
        .testTarget(
            name: "LineformCoreTests",
            dependencies: ["LineformCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
