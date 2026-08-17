# Development Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Xcode | 26+ | App Store / developer.apple.com |
| Homebrew | any | [brew.sh](https://brew.sh) |
| Swift | 6.2+ | Bundled with Xcode |

## Initial setup

```bash
git clone https://github.com/bocan/bocan-music.git
cd bocan-music

# Required before the project can be generated: project.yml references
# Secrets.xcconfig, so xcodegen fails without it. The template's empty
# defaults are fine; add real API keys later if you want those features
# (see "Local developer API keys" below).
cp Secrets.xcconfig.template Secrets.xcconfig

# Install all tools (swiftlint, swiftformat, xcbeautify, xcodegen, ...),
# bundle fpcalc + FFmpeg dylibs, and generate Bocan.xcodeproj. There is
# no separate generation step: bootstrap runs xcodegen at the end.
make bootstrap

# Verify environment
make doctor
```

`make generate` exists as a standalone target for later use: run it whenever
`project.yml` changes or files are added to globbed directories (`Tests/AppTests`,
`UITests`, `Resources`).

## Common commands

| Command | Description |
|---------|-------------|
| `make build` | Debug build |
| `make tests` | Format, lint, and the full test matrix in one run (`Scripts/run-tests.sh`) |
| `make test` | Xcode unit tests: view models, observability, App conventions (excludes snapshot tests) |
| `make test-coverage` | Tests + coverage report (>= 80% required) |
| `make coverage-all` | Per-module SPM coverage with module-level floors |
| `make test-<module>` | One SPM module's tests: `observability`, `persistence`, `metadata`, `library`, `acoustics`, `audio-engine`, `playback`, `scrobble`, `subsonic`, `podcasts`, `sync-server`, `ui` |
| `make test-ui` | UI module: snapshot + view-model tests (snapshot tests run only here, not in `make test`) |
| `make test-audio-engine` | AudioEngine SPM package tests (requires FFmpeg via Homebrew) |
| `make test-e2e` | Whole-app E2E journeys (XCUITest; launches the app repeatedly, opt-in, excluded from `make test` and CI) |
| `make test-e2e-smoke` | Curated <=10 minute E2E subset for a quick local pre-release check (ADR-079 journeys, menu crawl, one surface, one radio journey) |
| `make lint` | SwiftLint + SwiftFormat lint |
| `make format` | Auto-format all Swift files |
| `make format-check` | SwiftFormat lint mode (used in CI) |
| `make pseudolocale` | Regenerate the en-XA pseudolocale in the UI String Catalog |
| `make release-note` | Add a human note to the pending release PR's changelog. Never touch `release-please--branches--main` by hand: the bot force-recreates it every cycle, so a plain `git switch` lands on a stale local copy and `git pull` produces conflicts in every bot-owned file. The script force-resets onto the remote branch, opens `$EDITOR` on `CHANGELOG.md`, commits only that file, pushes to GitHub only (the Tangled/Codeberg mirrors reject this branch), and returns you to main, deleting the local branch copy so no stale fossil survives into the next cycle |
| `make clean` | Remove build artefacts |
| `make open` | Open in Xcode |
| `make generate` | Regenerate Xcode project from `project.yml` |
| `make doctor` | Print tool versions and verify the SwiftLint/SwiftFormat pins |

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
| `Persistence` | GRDB database, migrations, repositories, FTS5 search, `ValueObservation` streams |
| `AudioEngine` | `AudioEngine` actor, `EngineGraph`, `BufferPump`, FFmpeg bridge, DSP chain |
| `Metadata` | `TagReader`/`TagWriter` (TagLib), `CoverArtExtractor`, `LRCParser` |
| `Library` | `LibraryScanner`, FSEvents watcher, `ScanProgress`, cover-art cache |
| `Playback` | `QueuePlayer` actor, queue/history/shuffle, gapless + crossfade schedulers, MPNowPlaying |
| `Scrobble` | Last.fm / ListenBrainz / Rocksky providers, offline-resilient scrobble queue |
| `Subsonic` | `SubsonicService` actor, capability detection, Keychain credentials |
| `Acoustics` | Chromaprint fingerprinting, AcoustID + MusicBrainz lookup |
| `Podcasts` | RSS/Atom feed refresh, podcast search, subscriptions, episode downloads |
| `SyncServer` | Phone Sync: TLS identity, trust store, Bonjour-advertised sync server |
| `UI` | SwiftUI views, `LibraryViewModel`, `NowPlayingViewModel`, settings, mini player |

Dependency order (bottom → top; the middle tier all sits side by side):
```
Observability → Persistence → AudioEngine, Metadata, Library, Playback,
Scrobble, Subsonic, Acoustics, Podcasts, SyncServer → UI → App
```

### Test split: Xcode vs SPM

The `BocanTests` Xcode target runs in a **standalone** process (no host app, `TEST_HOST = ""`), which means AppKit rendering (and therefore snapshot tests) is not available there. Snapshot tests are part of the `UI` Swift package and run via `make test-ui` instead.

| Target | Command | Includes |
|--------|---------|----------|
| `BocanTests` (Xcode) | `make test` | View model tests, Observability tests, App source-convention tests |
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

## Local developer API keys

Some optional features require API keys in `Secrets.xcconfig` (copy from
`Secrets.xcconfig.template`, never commit). The app degrades gracefully when
any of these are absent.

| xcconfig key | Info.plist key | Feature | Where to get one |
|---|---|---|---|
| `ACOUSTID_API_KEY` | `AcoustIDAPIKey` | Track fingerprinting / AcoustID lookup | https://acoustid.org/my-applications |
| `BOCAN_LASTFM_API_KEY` / `BOCAN_LASTFM_SHARED_SECRET` | `BocanLastFmApiKey` / `BocanLastFmSharedSecret` | Last.fm scrobbling | https://www.last.fm/api/account/create |
| `PODCAST_INDEX_API_KEY` / `PODCAST_INDEX_API_SECRET` | `BocanPodcastIndexApiKey` / `BocanPodcastIndexApiSecret` | Podcast search via Podcast Index (ADR-040). Without these, search falls back to iTunes-only -- still fully functional, just half the index coverage. | https://api.podcastindex.org |

## Platform support

| Dimension | Decision | Rationale |
|-----------|----------|-----------|
| **Minimum macOS** | macOS 15 | `project.yml` sets `deploymentTarget: macOS 15.0`. Development requires Xcode 26 (and therefore a Mac running macOS 26), but the built app runs on macOS 15+. |
| **Architecture** | arm64 only | The bundled FFmpeg dylibs and `fpcalc` come from arm64 Homebrew (`/opt/homebrew`), whose prefix is hardcoded in the `Package.swift` build flags. A universal binary would double CI build time and require rebuilding every bundled dylib as universal, for a shrinking x86_64 user base. |
| **Intel (x86_64)** | Not supported | If Intel support is ever wanted, the arm64-only restriction in `Scripts/build-release.sh` and `.github/workflows/release.yml` must be revisited, all bundled dylibs rebuilt with `lipo`, and the hardcoded `/opt/homebrew` paths made prefix-aware. |

## Design docs

Architecture decision records are documented in [`docs/design-spec/`](docs/design-spec/README.md).
Start with `docs/design-spec/_standards.md`, then read the ADRs relevant to the area you are changing.

## FFmpeg (AudioEngine module)

The `AudioEngine` module decodes non-AVFoundation formats (OGG/Vorbis, Opus, DSD, APE, WavPack)
via FFmpeg using **Option B: system module + Homebrew dynamic linking**.

### Rationale

| Option | Pros | Cons |
|--------|------|------|
| A (vendored static libs) | No runtime dep | 100+ MB repo weight, GPL concerns |
| **B (system module, chosen)** | ~0 repo weight, easy updates | Homebrew required on dev + CI |
| C (SPM binary target) | Clean SPM | Complex packaging |

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



## fpcalc / AcoustID fingerprinting

Bòcan uses [Chromaprint](https://acoustid.org/chromaprint) (`fpcalc`) to generate acoustic fingerprints for track identification via the AcoustID API. Because the app runs in the macOS sandbox, `fpcalc` and all of its FFmpeg dylib dependencies must be bundled inside the app bundle with paths rewritten to `@loader_path`; it cannot reach out to Homebrew at runtime.

### Why the binaries are not in the repo

`fpcalc` transitively pulls in ~15 FFmpeg/codec dylibs (~32 MB total: libavcodec, libavformat, libavutil, libswresample, libssl, libcrypto, and several codec libs). Storing those in git would bloat every clone. Instead, `Scripts/build-fpcalc.sh` generates them locally and in CI from the Homebrew installation.

### Setup (done automatically by `make bootstrap`)

```bash
# Requires: brew install chromaprint ffmpeg  (both are in Brewfile)
make bundle-fpcalc
```

This runs `Scripts/build-fpcalc.sh`, which:

1. Copies `fpcalc` from `$(brew --prefix chromaprint)/bin/`.
2. Recursively walks every Homebrew dylib dependency of `fpcalc` and `libchromaprint`.
3. Copies each dylib into `Resources/` and rewrites all Homebrew-absolute paths to `@loader_path/<name>`.
4. Ad-hoc signs every binary (sufficient for Debug builds; release builds use a real Developer ID identity via `$SIGNING_IDENTITY`).

After the script runs, `make generate` picks up the new files in `Resources/` and XcodeGen adds them to the bundle automatically.

### Re-running after an FFmpeg or Chromaprint upgrade

```bash
make bundle-fpcalc   # re-copies and relinks all dylibs, then regenerates the Xcode project
```

`bundle-fpcalc` runs `xcodegen generate` itself, so the project picks up
renamed dylibs (e.g. `libavcodec.62` to `libavcodec.63`) automatically; no
separate `make generate` is needed.

### CI

The CI workflow (`ci.yml`) installs both `ffmpeg` and `chromaprint` via `brew bundle` (both are in the Brewfile). A dedicated step runs `make bundle-fpcalc` before `make generate` so all dylibs are present when XcodeGen scans `Resources/`.

### Signing for distribution

For a notarized release build, pass your Developer ID identity:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash Scripts/build-fpcalc.sh
```

Or set `$SIGNING_IDENTITY` in the environment before running `make bundle-fpcalc`.

## Debugging in Console.app

Filter by subsystem `io.cloudcauldron.bocan` to see all Bòcan log output.

## ADR-002 audit notes (audio engine)

A few ADR-002 implementation choices are worth flagging because they are not
discoverable from the spec alone:

- **DSP / EQ / Limiter chain landed in ADR-002.** The original plan
  scheduled these for ADR-013, but they were implemented up-front because
  every signal chain test fixture needed a stable insertion point. The chain
  is `PlayerNode → TimePitch → GainStage → EQ → BassBoost → Crossfeed →
  StereoExpander → Limiter → Mixer → Output`; every node is always present
  and individually bypassable. See `Modules/AudioEngine/Sources/AudioEngine/DSP/DSPChain.swift`.
- **Anti-pop fades.** The engine ramps `AVAudioPlayerNode.volume` over ~10 ms
  before any operation that truncates playback mid-cycle (`stop`, `pause`,
  `seek`, track-change). This is a separate gain stage from the user-volume
  mixer and the ReplayGain `GainStage`; do not collapse them.
- **`make bundle-fpcalc`.** Re-link the bundled `fpcalc` and dependent
  FFmpeg dylibs whenever Homebrew bumps FFmpeg's major version (e.g.
  `libavcodec.61` → `libavcodec.62`). The script also re-signs the binaries
  with the ad-hoc identity; pass `SIGNING_IDENTITY` for Developer-ID builds.
- **Thread Sanitizer on the test action.** `Scripts/patch-scheme.sh` is run
  by `xcodegen` (via `postGenCommand`) to enable TSan in the generated
  scheme, because XcodeGen has no first-class flag for it.
