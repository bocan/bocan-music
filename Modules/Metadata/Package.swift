// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Metadata",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "Metadata",
            targets: ["Metadata"]
        ),
    ],
    dependencies: [
        .package(path: "../Observability"),
    ],
    targets: [
        // Obj-C++ bridge to TagLib 2.x
        .target(
            name: "TagLibBridge",
            path: "Sources/TagLibBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-fexceptions",
                    "-fcxx-exceptions",
                    "-I/opt/homebrew/include",
                    "-I/opt/homebrew/include/taglib",
                    "-I/usr/local/include",
                    "-I/usr/local/include/taglib",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("tag"),
                .linkedLibrary("z"),
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/opt/homebrew/Cellar/taglib/2.2.1/lib",
                ]),
            ]
        ),
        // Swift facade
        .target(
            name: "Metadata",
            dependencies: [
                "TagLibBridge",
                .product(name: "Observability", package: "Observability"),
            ],
            path: "Sources/Metadata",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        // Tests
        .testTarget(
            name: "MetadataTests",
            dependencies: ["Metadata"],
            path: "Tests/MetadataTests",
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
