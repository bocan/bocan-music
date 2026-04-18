// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../Observability"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Observability", package: "Observability"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
