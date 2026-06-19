// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Podcasts",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Podcasts", targets: ["Podcasts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "Podcasts",
            dependencies: [
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "PodcastsTests",
            dependencies: [
                "Podcasts",
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
