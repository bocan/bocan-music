// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "Library",
            targets: ["Library"]
        ),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../Metadata"),
        .package(path: "../Acoustics"),
    ],
    targets: [
        .target(
            name: "Library",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "Metadata", package: "Metadata"),
                .product(name: "Acoustics", package: "Acoustics"),
            ],
            path: "Sources/Library",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "LibraryTests",
            dependencies: [
                "Library",
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "Metadata", package: "Metadata"),
            ],
            path: "Tests/LibraryTests",
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
