// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Metadata",
    platforms: [
        .macOS(.v15),
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
                    // TagLib's own keg, never the shared /opt/homebrew/include
                    // or /opt/homebrew/lib: those also hold Homebrew's GPL
                    // FFmpeg when it is installed, and a linker flag here
                    // reaches the final link of every product (ADR-096).
                    "-I/opt/homebrew/opt/taglib/include",
                    "-I/opt/homebrew/opt/taglib/include/taglib",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("tag"),
                .linkedLibrary("z"),
                .unsafeFlags([
                    "-L/opt/homebrew/opt/taglib/lib",
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
