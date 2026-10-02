// swift-tools-version: 6.2

import PackageDescription

/// The LGPL FFmpeg that AudioEngine links (AudioEngine/Package.swift, ADR-096).
/// This package loads the CFFmpeg module through AudioEngine, and unsafeFlags
/// do not cross package boundaries, so it names the same headers. Never point
/// this at /opt/homebrew/include: that is Homebrew's GPL FFmpeg.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"]
    ?? "\(Context.packageDirectory)/../../build/ffmpeg-lgpl"

let package = Package(
    name: "Playback",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Playback", targets: ["Playback"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../AudioEngine"),
    ],
    targets: [
        .target(
            name: "Playback",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "AudioEngine", package: "AudioEngine"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: [
                "Playback",
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
    ]
)
