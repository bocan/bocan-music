// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioEngine",
    platforms: [
        .macOS(.v15),
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
                // Homebrew's pkg-config (now pkgconf) stopped feeding system
                // include paths through Xcode's SPM clang module scanner, so
                // the CFFmpeg module failed to resolve <libavcodec/avcodec.h>
                // under `xcodebuild`. Inject the Homebrew prefix explicitly
                // (ARM64 Homebrew is assumed — both local dev Macs and the
                // GitHub xcode-27 runners use /opt/homebrew).
                //
                // Kept as insurance, not because it is currently load-bearing:
                // a cold xcodebuild and a clean `swift build` both succeed with
                // every copy of this flag removed (#549, measured 2026-09-20 on
                // Xcode 27 with ffmpeg 9.0.1_1). Re-test before removing it,
                // and see docs/GOTCHAS.md for the procedure.
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
