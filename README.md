# Bòcan

[![CI](https://github.com/bocan/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/ci.yml)
[![CodeQL](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![Xcode 26](https://img.shields.io/badge/Xcode-26-1575F9)

A native macOS music player built the old-fashioned way — no Catalyst, no Electron, no cross-platform abstractions. Swift 6 strict concurrency, SwiftUI, GRDB, AVFoundation, and FFmpeg under the hood; every module ships its own test suite.

## On the name

**Bòcan** (Scottish Gaelic, roughly *BAW-khan*) is a hobgoblin — the household spirit that curates your music library while you sleep. See [spec.md](spec.md) for the full etymology; the short version is that computers don't like `ò`, so the binary, bundle, and repository all use `bocan`.

## Features

### Playback

- Sample-accurate **gapless playback** with a pre-decoded secondary player node and `AVAudioTime`-anchored handoff.
- **FFmpeg-backed decoders** for Ogg Vorbis, Opus, APE, WavPack, and DSD, alongside AVFoundation's native formats (FLAC, ALAC, AAC, MP3, WAV, AIFF).
- Dedicated `AudioEngine` actor with a stable ring-buffer pump and format-converter stage; strict concurrency enforced.
- **Queue management** with a proper `PlaybackQueue` backing type, full history, and multiple shuffle strategies (Fisher–Yates + smart/weighted).
- MPNowPlayingInfoCenter + remote command centre integration for media keys and Control Centre.
- Now-playing persistence across launches.

### Library

- **Folder-based library** rooted at one or more user-chosen directories, with security-scoped bookmarks for sandbox compliance.
- Full scan + incremental **quick scan** (FSEvents-driven), deduplicated at file-fingerprint level.
- TagLib-backed metadata read/write (title, artist, album, track/disc numbers, year, genre, embedded cover art, embedded lyrics).
- **Change detection** respects user edits (`user_edited = 1` suppresses tag overwrites on rescan).
- Cover-art cache with content-addressed storage under `~/Library/Application Support`.
- **Add Files / Add Folder** pickers for one-off imports outside the managed roots.
- Conflict resolver for ambiguous metadata and duplicate detection.

### Browser & UI

- Three-pane SwiftUI browser: sidebar, artist/album/track columns, inspector.
- **Sortable, filterable tracks table** with title/artist/album/duration/play-count/added-at columns.
- Artist and album lookups populated in bulk (no per-row N+1 queries).
- Dedicated views for Albums grid, Tracks list, Recently Added, and Artists.
- **Now Playing strip** with scrubber, volume, and transport controls.
- Theming that honours system light/dark mode; snapshot-tested on developer machines.
- Accessibility: VoiceOver labels, keyboard shortcuts, reduced-motion support.
- **Empty states** and loading placeholders throughout.

### Persistence

- **GRDB 7** schema with explicit migrations, FTS5 search index, and typed repositories per entity (`Track`, `Album`, `Artist`, `LibraryRoot`, `PlayCount`, `Cover`, `Lyrics`).
- `ValueObservation`-based async streams feed SwiftUI view models reactively.
- In-memory database for tests; WAL-mode on-disk at runtime.
- Performance-tested on 10 000-track libraries.

### Observability

- Structured `AppLogger` over `os.Logger` with subsystem `io.cloudcauldron.bocan` — filter by it in Console.app.
- MetricKit listener for crashes, hangs, and signpost data.
- Telemetry primitives (counters, deferrable timers) with zero runtime dependencies.

### Engineering

- **Seven SPM modules**: `Observability`, `AudioEngine`, `Persistence`, `Metadata`, `Library`, `Playback`, `UI`.
- Swift 6 strict concurrency across every module.
- Unit, integration, performance, and snapshot suites via **swift-testing**.
- Coverage gate at 80% on `make test-coverage`.
- **SwiftLint + SwiftFormat** enforced on every commit via pre-commit hook and CI.
- **CodeQL** weekly + on every PR (`security-and-quality` query pack).
- Dependabot on all seven SPM manifests and GitHub Actions workflows.
- XcodeGen-generated project (`project.yml`) — no hand-edited `.pbxproj`.

## Naming

| Property | Value |
|----------|-------|
| Display name | Bòcan |
| Binary / package name | `bocan` |
| Bundle ID | `io.cloudcauldron.bocan` |
| Log subsystem | `io.cloudcauldron.bocan` |
| Minimum macOS | 14.0 (Sonoma) |

## Requirements

- macOS 14.0+
- Xcode 26+
- Homebrew (for FFmpeg, TagLib, swiftlint, swiftformat, xcodegen, xcbeautify)

## Quick start

```bash
git clone https://github.com/bocan/bocan-music.git
cd bocan-music
make bootstrap     # brew bundle + install git hooks
make generate      # xcodegen → Bocan.xcodeproj
make open          # opens in Xcode
```

Run the tests:

```bash
make test                 # full Xcode test bundle (view models + observability)
make test-coverage        # + coverage report, fails < 80%
make test-audio-engine    # AudioEngine SPM tests (FFmpeg required)
make test-persistence     # Persistence SPM tests
make test-metadata        # Metadata SPM tests
make test-library         # Library SPM tests
make test-ui              # UI module: view-model + snapshot tests
```

## Modules

| Module | Description |
|--------|-------------|
| `Observability` | Structured logging (`AppLogger`), telemetry, MetricKit |
| `AudioEngine` | AVFoundation + FFmpeg decoder graph, ring buffer, playback actor |
| `Persistence` | GRDB schema + migrations, repositories, reactive `ValueObservation` |
| `Metadata` | TagLib read/write, cover-art extraction, LRC lyric parser |
| `Library` | Folder scanner, FSEvents watcher, conflict resolver, cover-art cache |
| `Playback` | Queue, history, shuffle strategies, gapless scheduler, MPNowPlaying |
| `UI` | SwiftUI views, view models, theming, snapshot tests |

## Project status

Phases 0 – 5.5 are complete (foundations, audio engine, persistence, library scanning, library UI, queue/gapless, add-files). Manual playlists (phase 6) are next. See [`phases/`](phases/README.md) for the full roadmap through distribution (phase 16).

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for detailed setup, the build system, FFmpeg notes, and contribution guidelines.

## Licence

See [LICENSE](LICENSE).
# Bòcan

[![CI](https://github.com/bocan/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/ci.yml)

A native macOS music player. Built with Swift 6, SwiftUI, and AVFoundation.

## Naming

| Property | Value |
|----------|-------|
| Display name | Bòcan |
| Binary / package name | `bocan` |
| Bundle ID | `io.cloudcauldron.bocan` |
| Log subsystem | `io.cloudcauldron.bocan` |
| Minimum macOS | 14.0 (Sonoma) |

## Requirements

- macOS 14.0+
- Xcode 16+
- Homebrew

## Quick start

```bash
git clone https://github.com/bocan/bocan-music.git
cd bocan-music
make bootstrap
make generate
make open          # opens Bocan.xcodeproj
```

Run the test suite:

```bash
make test          # Xcode unit tests (view models + observability)
make test-ui       # UI module: snapshot + view-model tests via swift test
```

## Modules

| Module | Description |
|--------|-------------|
| `Observability` | Structured logging (`AppLogger`), telemetry, MetricKit |
| `AudioEngine` | AVFoundation + FFmpeg decoder graph, playback actor |
| `Persistence` | GRDB schema, repositories, async observation |
| `Metadata` | TagLib tag reading/writing, cover art extraction, LRC parser |
| `Library` | Folder scanner, FSEvents watcher, library index |
| `UI` | SwiftUI views, view models, snapshot tests |

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for detailed setup, the build system, and contribution guidelines.

## Phase specs

All build phases are documented in [`phases/`](phases/README.md).
