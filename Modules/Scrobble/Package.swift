// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Scrobble",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Scrobble", targets: ["Scrobble"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../Playback"),
    ],
    targets: [
        .target(
            name: "Scrobble",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "Playback", package: "Playback"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // See AudioEngine/Package.swift: pkgconf's cflags don't reach
                // Xcode's SPM clang module scanner, so any package that
                // transitively imports CFFmpeg (via the Playback -> AudioEngine
                // product chain) needs this same explicit Homebrew include
                // path -- unsafeFlags don't propagate across package boundaries.
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ]
        ),
        .testTarget(
            name: "ScrobbleTests",
            dependencies: ["Scrobble"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ]
        ),
    ]
)
