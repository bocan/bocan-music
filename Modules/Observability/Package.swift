// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Observability",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "Observability", targets: ["Observability"]),
    ],
    targets: [
        .target(
            name: "Observability",
            dependencies: [],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "ObservabilityTests",
            dependencies: ["Observability"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
