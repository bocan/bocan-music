// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudioEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
    ],
    targets: [
        // C system-module wrapping Homebrew FFmpeg (pkg-config: ffmpeg).
        // Decision: Option B — in-tree CFFmpeg linking Homebrew FFmpeg dynamically.
        // See DEVELOPMENT.md §FFmpeg for rationale and CI setup.
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libswresample libavutil",
            providers: [.brew(["ffmpeg"])]
        ),

        .target(
            name: "AudioEngine",
            dependencies: [
                "CFFmpeg",
                .product(name: "Observability", package: "Observability"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
