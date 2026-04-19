# Development Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Xcode | 16+ | App Store / developer.apple.com |
| Homebrew | any | [brew.sh](https://brew.sh) |
| Swift | 6.0+ | Bundled with Xcode |

## Initial setup

```bash
git clone https://github.com/cloudcauldron/bocan-music.git
cd bocan-music

# Install all tools (swiftlint, swiftformat, xcbeautify, xcodegen, …)
make bootstrap

# Generate Bocan.xcodeproj from project.yml
make generate

# Verify environment
make doctor
```

## Common commands

| Command | Description |
|---------|-------------|
| `make build` | Debug build |
| `make test` | Xcode unit tests — view models + observability (excludes snapshot tests) |
| `make test-coverage` | Tests + coverage report (≥ 80% required) |
| `make test-ui` | UI module: snapshot + view-model tests via `swift test` |
| `make test-audio-engine` | AudioEngine SPM package tests (requires FFmpeg via Homebrew) |
| `make test-persistence` | Persistence SPM package tests |
| `make test-metadata` | Metadata SPM package tests |
| `make test-library` | Library SPM package tests |
| `make lint` | SwiftLint + SwiftFormat lint |
| `make format` | Auto-format all Swift files |
| `make format-check` | SwiftFormat lint mode (used in CI) |
| `make clean` | Remove build artefacts |
| `make open` | Open in Xcode |
| `make generate` | Regenerate Xcode project from `project.yml` |

## Xcode project

The project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen).
**Do not hand-edit `.pbxproj`**. Edit `project.yml` and run `make generate`.

## Module layout

All modules live under `Modules/` as independent Swift packages.

```
Modules/<Name>/
├── Package.swift
├── Sources/<Name>/
└── Tests/<Name>Tests/
```

| Module | Key contents |
|--------|--------------|
| `Observability` | `AppLogger`, `Telemetry`, `MetricKitListener`, `Redaction` |
| `AudioEngine` | `AudioEngine` actor, `EngineGraph`, `BufferPump`, FFmpeg bridge |
| `Persistence` | GRDB database, migrations, repositories, `AsyncObservation` |
| `Metadata` | `TagReader`/`TagWriter` (TagLib), `CoverArtExtractor`, `LRCParser` |
| `Library` | `LibraryScanner`, FSEvents watcher, `ScanProgress` |
| `UI` | SwiftUI views, `LibraryViewModel`, `NowPlayingViewModel`, `TracksViewModel`, `AlbumsViewModel`, `SearchViewModel` |

Dependency order (bottom → top):
```
Observability → Persistence → AudioEngine → Metadata → Library → UI → App
```

### Test split: Xcode vs SPM

The `BocanTests` Xcode target runs in a **standalone** process (no host app, `TEST_HOST = ""`), which means AppKit rendering — and therefore snapshot tests — is not available. Snapshot tests are part of the `UI` Swift package and run via `make test-ui` instead.

| Target | Command | Includes |
|--------|---------|----------|
| `BocanTests` (Xcode) | `make test` | View model tests, Observability tests |
| `UI` package | `make test-ui` | View model tests + snapshot tests |

## Secrets (for release builds)

The following secrets are required in GitHub Actions for the release workflow.
Never commit these to the repo.

| Secret | Description |
|--------|-------------|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded Developer ID Application cert (.p12) |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the .p12 |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APP_SPECIFIC_PASSWORD` | App-specific password for notarytool |

## Phases

Implementation phases are documented in [`phases/`](phases/README.md).
Start with `phases/_standards.md`, then tackle one phase at a time.

## FFmpeg (AudioEngine module)

The `AudioEngine` module decodes non-AVFoundation formats (OGG/Vorbis, Opus, DSD, APE, WavPack)
via FFmpeg using **Option B: system module + Homebrew dynamic linking**.

### Rationale

| Option | Pros | Cons |
|--------|------|------|
| A — vendored static libs | No runtime dep | 100+ MB repo weight, GPL concerns |
| **B — system module (chosen)** | ~0 repo weight, easy updates | Homebrew required on dev + CI |
| C — SPM binary target | Clean SPM | Complex packaging |

### Setup

```bash
brew install ffmpeg           # installed automatically by make bootstrap
make doctor                   # verifies pkg-config finds libavformat etc.
```

### Building AudioEngine outside Xcode

```bash
cd Modules/AudioEngine
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig swift build
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig swift test
# or simply:
make test-audio-engine        # (PKG_CONFIG_PATH already in $GITHUB_ENV on CI)
```

### Key Swift concurrency decisions

| Pattern | Reason |
|---------|--------|
| `@preconcurrency import AVFoundation` | `AVAudioPCMBuffer` lacks `Sendable`; suppress cascade errors |
| `EngineGraph: @unchecked Sendable` class (not actor) | `AVAudioPlayerNode` can't cross actor boundaries; safety ensured by owning `AudioEngine` actor |
| `nonisolated public let state` | `AsyncStream` is `Sendable`; `let` is immutable so `nonisolated` is safe |



## Debugging in Console.app

Filter by subsystem `io.cloudcauldron.bocan` to see all Bòcan log output.
