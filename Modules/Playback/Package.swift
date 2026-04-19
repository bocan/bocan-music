// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Playback",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Playback", targets: ["Playback"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../AudioEngine"),
    ],
    targets: [
        .target(
            name: "Playback",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "AudioEngine", package: "AudioEngine"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: [
                "Playback",
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
