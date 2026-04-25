// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Acoustics",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Acoustics", targets: ["Acoustics"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
    ],
    targets: [
        .target(
            name: "Acoustics",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AcousticsTests",
            dependencies: ["Acoustics"],
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
