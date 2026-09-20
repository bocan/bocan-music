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
                // See AudioEngine/Package.swift. Carried here because
                // unsafeFlags do not propagate across package boundaries, not
                // because this target is known to need it (#549).
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
