// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Jellyfin",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Jellyfin", targets: ["Jellyfin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift", from: "3.4.0"),
        // The SDK's HTTP layer. Named here because `APIError` carries the HTTP
        // status the module maps to its own errors; the SDK does not re-export it.
        .package(url: "https://github.com/kean/Get", from: "2.2.1"),
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "Jellyfin",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Get", package: "Get"),
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "JellyfinTests",
            dependencies: [
                "Jellyfin",
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Get", package: "Get"),
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            resources: [
                // Captured-shape Jellyfin responses, checked in. Tests never hit the network.
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
