// swift-tools-version: 6.2

import PackageDescription

/// The LGPL FFmpeg that AudioEngine links (AudioEngine/Package.swift, ADR-096).
/// This package loads the CFFmpeg module through AudioEngine, and unsafeFlags
/// do not cross package boundaries, so it names the same headers. Never point
/// this at /opt/homebrew/include: that is Homebrew's GPL FFmpeg.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"]
    ?? "\(Context.packageDirectory)/../../build/ffmpeg-lgpl"

let package = Package(
    name: "SyncServer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SyncServer", targets: ["SyncServer"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
        .package(path: "../AudioEngine"),
        .package(path: "../Library"),
        .package(path: "../Metadata"),
        .package(path: "../Podcasts"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.2"),
    ],
    targets: [
        .target(
            name: "SyncServer",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
                // ADR-088: the transcode coordinator drives AudioTranscoder.
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Library", package: "Library"),
                .product(name: "Metadata", package: "Metadata"),
                .product(name: "Podcasts", package: "Podcasts"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
        .testTarget(
            name: "SyncServerTests",
            dependencies: [
                "SyncServer",
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
    ]
)
