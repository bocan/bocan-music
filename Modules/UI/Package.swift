// swift-tools-version: 6.2

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
        .package(path: "../Subsonic"),
        .package(
            url: "https://github.com/MathieuDubart/swiftsonic.git",
            from: "0.8.2"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            from: "1.19.2"
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
                .product(name: "Subsonic", package: "Subsonic"),
                .product(name: "SwiftSonic", package: "swiftsonic"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "UITests",
            dependencies: [
                "UI",
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "Library", package: "Library"),
                .product(name: "Subsonic", package: "Subsonic"),
                .product(name: "SwiftSonic", package: "swiftsonic"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
