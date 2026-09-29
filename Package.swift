// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "m2m",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "M2MCore", targets: ["M2MCore"]),
        .executable(name: "m2mhost", targets: ["M2MHostCLI"]),
        .executable(name: "m2mviewer", targets: ["M2MViewerCLI"]),
        .executable(name: "m2mdemo", targets: ["M2MDemoCLI"]),
        .executable(name: "m2mctl", targets: ["M2MCtlCLI"]),
    ],
    targets: [
        .target(
            name: "M2MCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "M2MHostCLI",
            dependencies: ["M2MCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "M2MViewerCLI",
            dependencies: ["M2MCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "M2MDemoCLI",
            dependencies: ["M2MCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "M2MCtlCLI",
            dependencies: ["M2MCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "M2MCoreTests",
            dependencies: ["M2MCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
