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
| `make test` | Run all tests |
| `make test-coverage` | Tests + coverage report (≥ 80% required) |
| `make lint` | SwiftLint + SwiftFormat lint |
| `make format` | Auto-format all Swift files |
| `make clean` | Remove build artefacts |
| `make open` | Open in Xcode |
| `make generate` | Regenerate Xcode project from `project.yml` |

## Xcode project

The project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen).
**Do not hand-edit `.pbxproj`**. Edit `project.yml` and run `make generate`.

## Module layout

```
Modules/<Name>/
├── Package.swift
├── Sources/<Name>/
└── Tests/<Name>Tests/
```

Dependency order (bottom → top): `Observability → Persistence → AudioEngine → Metadata → Library → Playback → UI → App`

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

## Debugging in Console.app

Filter by subsystem `io.cloudcauldron.bocan` to see all Bòcan log output.
