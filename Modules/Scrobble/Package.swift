// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scrobble",
    platforms: [
        .macOS(.v14),
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
            ]
        ),
        .testTarget(
            name: "ScrobbleTests",
            dependencies: ["Scrobble"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
