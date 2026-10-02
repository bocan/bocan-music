// swift-tools-version: 6.2

import PackageDescription

// The FFmpeg every build links: the project's own LGPL source build
// (ADR-096), made by `make ffmpeg-lgpl` into build/ffmpeg-lgpl at the repo
// root. It is named by path here, and not found through pkg-config, on
// purpose: Xcode does not pass the shell environment to SwiftPM, so a
// pkg-config lookup there finds Homebrew's GPL FFmpeg when it is installed.
// FFMPEG_PREFIX overrides the path for command-line builds (a worktree that
// shares one build, for example).
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"]
    ?? "\(Context.packageDirectory)/../../build/ffmpeg-lgpl"

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
        // C system-module wrapping FFmpeg, linked dynamically from
        // `ffmpegPrefix`. No `pkgConfig:` (see the note at the top); the
        // targets that import it pass the header and library paths.
        // See DEVELOPMENT.md §FFmpeg.
        .systemLibrary(name: "CFFmpeg"),

        // The render blocks of the custom audio units, in Objective-C so that
        // no Swift code runs on the real-time thread (docs/GOTCHAS.md).
        .target(
            name: "AudioEngineKernels",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
            ]
        ),

        .target(
            name: "AudioEngine",
            dependencies: [
                "CFFmpeg",
                "AudioEngineKernels",
                .product(name: "Observability", package: "Observability"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // The CFFmpeg headers. Never add -I/opt/homebrew/include or
                // -L/opt/homebrew/lib here: with Homebrew's FFmpeg installed
                // they make the build take that GPL library in place of this
                // one, and nothing fails (ADR-096).
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegPrefix)/lib"]),
            ]
        ),

        // Test support, in Objective-C: drives a unit's render block the way
        // Core Audio does and counts the heap allocations the render makes.
        .target(
            name: "RenderProbe",
            path: "Tests/RenderProbe",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
            ]
        ),

        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine", "RenderProbe"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegPrefix)/lib"]),
            ]
        ),
    ]
)
