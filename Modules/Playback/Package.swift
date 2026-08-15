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
                // See AudioEngine/Package.swift: pkgconf's cflags don't reach
                // Xcode's SPM clang module scanner, so any package that
                // transitively imports CFFmpeg (via the AudioEngine product)
                // needs this same explicit Homebrew include path, not just
                // AudioEngine's own target -- unsafeFlags don't propagate
                // across package boundaries.
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
