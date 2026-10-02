// swift-tools-version: 6.2

import PackageDescription

/// The LGPL FFmpeg that AudioEngine links (AudioEngine/Package.swift, ADR-096).
/// This package loads the CFFmpeg module through Playback and AudioEngine, and
/// unsafeFlags do not cross package boundaries, so it names the same headers.
/// Never point this at /opt/homebrew/include: that is Homebrew's GPL FFmpeg.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"]
    ?? "\(Context.packageDirectory)/../../build/ffmpeg-lgpl"

let package = Package(
    name: "Scrobble",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Scrobble", targets: ["Scrobble"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../Playback"),
    ],
    targets: [
        .target(
            name: "Scrobble",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "Playback", package: "Playback"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
        .testTarget(
            name: "ScrobbleTests",
            dependencies: ["Scrobble"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
    ]
)
