// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UI",
    platforms: [
        .macOS(.v15),
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
        .package(path: "../Scrobble"),
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
                .product(name: "Scrobble", package: "Scrobble"),
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
                .product(name: "Library", package: "Library"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
