// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SyncServer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SyncServer", targets: ["SyncServer"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
    ],
    targets: [
        .target(
            name: "SyncServer",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SyncServerTests",
            dependencies: [
                "SyncServer",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
