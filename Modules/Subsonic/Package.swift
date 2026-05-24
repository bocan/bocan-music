// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Subsonic",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Subsonic", targets: ["Subsonic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MathieuDubart/swiftsonic.git", from: "0.8.2"),
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "Subsonic",
            dependencies: [
                .product(name: "SwiftSonic", package: "swiftsonic"),
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SubsonicTests",
            dependencies: [
                "Subsonic",
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
