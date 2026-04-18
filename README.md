# Bòcan

[![CI](https://github.com/cloudcauldron/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/cloudcauldron/bocan-music/actions/workflows/ci.yml)

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
git clone https://github.com/cloudcauldron/bocan-music.git
cd bocan-music
make bootstrap
make generate
make open          # opens Bocan.xcodeproj
```

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for detailed setup, the build system, and contribution guidelines.

## Phase specs

All build phases are documented in [`phases/`](phases/README.md).
