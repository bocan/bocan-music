// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "bocan-schema", targets: ["BocanSchema"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
        .executableTarget(
            name: "BocanSchema",
            dependencies: ["Persistence"],
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
