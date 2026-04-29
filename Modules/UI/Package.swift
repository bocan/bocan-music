// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../AudioEngine"),
        .package(path: "../Playback"),
        .package(path: "../Library"),
        .package(path: "../Acoustics"),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            from: "1.17.0"
        ),
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Playback", package: "Playback"),
                .product(name: "Library", package: "Library"),
                .product(name: "Acoustics", package: "Acoustics"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "UITests",
            dependencies: [
                "UI",
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
