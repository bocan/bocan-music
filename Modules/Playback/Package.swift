// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Playback",
    platforms: [
        .macOS(.v15),
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
                // See AudioEngine/Package.swift. Carried by every package that
                // transitively imports CFFmpeg, because unsafeFlags do not
                // propagate across package boundaries. `SyncServer` is the
                // exception and needs no change: it imports AudioEngine and
                // builds clean without this, which is what #549 measured.
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
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
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ]
        ),
    ]
)
