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
