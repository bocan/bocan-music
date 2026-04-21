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
                // Homebrew's pkg-config (now pkgconf) no longer feeds system
                // include paths through Xcode's SPM clang module scanner, so
                // the CFFmpeg module fails to resolve <libavcodec/avcodec.h>
                // under `xcodebuild`. Inject the Homebrew prefix explicitly
                // (ARM64 Homebrew is assumed — both local dev Macs and the
                // GitHub macos-26 runners use /opt/homebrew).
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
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
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),
    ]
)
