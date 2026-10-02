# Development Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Xcode | 27 | App Store / developer.apple.com (needs a Mac running macOS 27) |
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
# build FFmpeg and fpcalc from source (see "FFmpeg" below), bundle fpcalc
# and its dylibs, and generate Bocan.xcodeproj. There is no separate
# generation step: bootstrap runs xcodegen at the end. The first run takes
# a few minutes, because it downloads and builds FFmpeg and Chromaprint.
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
| `make test-audio-engine` | AudioEngine SPM package tests (requires the project's LGPL FFmpeg build: `make ffmpeg-lgpl`) |
| `make test-e2e` | Whole-app E2E journeys (XCUITest; launches the app repeatedly, opt-in, excluded from `make test` and CI) |
| `make test-e2e-smoke` | Curated <=10 minute E2E subset for a quick local pre-release check (ADR-079 journeys, menu crawl, one surface, one radio journey, and the track context menu inside an album opened from the grid) |
| `make lint` | SwiftLint (strict), the help-text, `try?` and AppKit-import audits, and the check that the workspace `Package.resolved` is tracked. It does not run SwiftFormat; that is `make format-check` |
| `make format` | Auto-format all Swift files |
| `make format-check` | SwiftFormat lint mode (used in CI) |
| `make pseudolocale` | Regenerate the en-XA pseudolocale in the UI String Catalog |
| `make release-preview` | Show the version the next release would get and the `CHANGELOG.md` section it would write. Nothing is changed. Release notes are not added by a command: each `feat`, `fix` or `perf` PR writes its own under `## [Unreleased]` (see "Releasing" below) |
| `make audit-db` | Data-level schema audit against a library database (a `.backup` copy, never the live file). The default is the Debug build's library in the sandbox container; pass `DB=/path/to/library.sqlite` for another one, such as the release library in `~/Library/Application Support/Bocan/`. `Scripts/audit-db-schema.py` reports columns that are 100% NULL, stuck at their DDL default, or over 90% NULL; `Scripts/audit-db-xref.py` reports columns no Swift source outside migrations and tests references. See issue #414 for why this exists |
| `make data-dictionary` | Regenerate `docs/data-dictionary.md` from a freshly migrated schema (`swift run bocan-schema` in `Modules/Persistence`), merging the curated `docs/data-dictionary-notes.json`; `DB=/path/to/library.sqlite` documents a real library instead. Edit the notes file, never the generated tables |
| `make clean` | Remove build artefacts |
| `make open` | Open in Xcode |
| `make generate` | Regenerate Xcode project from `project.yml` |
| `make doctor` | Print tool versions and verify the SwiftLint/SwiftFormat pins and the FFmpeg build: it is there, it is LGPL v2.1 or later, and the `fpcalc` dylibs in `Resources/` come from the same library majors (`Scripts/check-ffmpeg-build.sh`) |
| `make ffmpeg-lgpl` | Build the FFmpeg that every build links, from the pinned source, into `build/ffmpeg-lgpl` (see "FFmpeg" below). Does nothing when the build is up to date |
| `make bundle-fpcalc` | Build `fpcalc` from the pinned Chromaprint source against that FFmpeg, bundle it with its dylibs into `Resources/`, and regenerate the Xcode project |
| `make check-licence APP=path/to/Bocan.app` | The licence gate: fail unless every FFmpeg library in a built app is the LGPL build (`Scripts/check-bundle-licence.sh`) |

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

Dependency order (bottom → top):
```
Observability → { AudioEngine, Metadata, Acoustics, Persistence }
              → { Subsonic, Podcasts, Library, Playback }
              → { Scrobble, SyncServer } → UI → App
```

The modules inside a tier are not all independent: `Library` depends on
`Metadata` and `Acoustics`, `Playback` on `AudioEngine`, `Scrobble` on
`Playback`, and `SyncServer` on `AudioEngine`, `Library`, `Metadata` and
`Podcasts`. The table in `docs/design-spec/_standards.md` ("Module layout")
lists every edge.

### Test split: Xcode vs SPM

The `BocanTests` Xcode target runs in a **standalone** process (no host app, `TEST_HOST = ""`), which means AppKit rendering (and therefore snapshot tests) is not available there. Snapshot tests are part of the `UI` Swift package and run via `make test-ui` instead.

| Target | Command | Includes |
|--------|---------|----------|
| `BocanTests` (Xcode) | `make test` | View model tests, Observability tests, App source-convention tests |
| `UI` package | `make test-ui` | View model tests + snapshot tests |

### Test fixtures

Audio fixtures are **checked in**, never generated at test time (see `CLAUDE.md`): tests read them from `Bundle.module`, so CI and `make test-*` never invoke ffmpeg and results do not depend on which encoders a machine has. Each fixture set has a generator script so the binaries stay reproducible; run one only when you need to change a fixture, delete the affected files first (the scripts skip files that already exist), then commit the output.

| Script | Produces | Used by |
|--------|----------|---------|
| `Scripts/gen-audio-fixtures.sh` | Single-file format samples in `Modules/Metadata/Tests/MetadataTests/Fixtures/` (16 and 24 bit, lossy, a `KEY` comment) | `TagReader` / `TagWriter` tests |
| `Scripts/gen-library-fixtures.sh` | `Modules/Library/Tests/LibraryTests/Fixtures/sample-library/`, an untagged multi-artist tree with edge cases (hidden file, corrupt file, unicode name) | scan lifecycle and count tests |
| `Scripts/gen-picard-fixtures.sh` | `Modules/Library/Tests/LibraryTests/Fixtures/picard-library/`, a Picard-tagged tree: MusicBrainz ids, sort tags, release types, totals in both `TRACKTOTAL` and `n/N` form, 16 and 24 bit, embedded and sidecar art, an album mixed from two release ids | `PicardLibraryScanTests` (row assertions) and `ColumnPopulationGuardTests` |

Two things about the Picard set:

- ffmpeg cannot write the iTunes freeform atoms TagLib reads, so the M4A's MusicBrainz ids and release type are written with Bòcan's own `TagWriter` by `PicardFixtureFinisherTests` in the Metadata package. It is skipped unless `BOCAN_FINISH_PICARD_FIXTURE=1`; run `cd Modules/Metadata && BOCAN_FINISH_PICARD_FIXTURE=1 swift test --filter PicardFixtureFinisherTests` after regenerating the M4A.
- `ColumnPopulationGuardTests` scans that set and requires every column of `tracks`, `albums`, `artists` and `cover_art` to be populated (non-NULL, non-DEFAULT) on at least one row, or to appear in its allow-list with a reason. A stale allowance fails too. When you add a column, either give the fixture a tag the importer turns into it, or add a justified line to the allow-list; this is the CI side of the schema-discipline rule in `CLAUDE.md`.

## Releasing

A release is a decision, never a side effect of merging (ADR-033). The notes
are written before the release exists, one PR at a time:

1. Every `feat`, `fix` or `perf` PR adds one or two plain sentences under
   `## [Unreleased]` in `CHANGELOG.md`, written for the person reading the
   update prompt (no code names, no PR numbers). The `Release note in
   CHANGELOG Unreleased` check refuses the PR otherwise; label it
   `skip-changelog` if the change is not user-visible.
2. When you want to ship, run `make release-preview` to see the version the
   squash commits since the last tag imply and the section that will be
   written (nothing is changed locally). Then Actions > Release > Run
   workflow, with no input. The workflow:
   - runs `Scripts/release.sh apply`: `Unreleased` becomes `## [X.Y.Z]` with
     your prose on top and a generated `### For developers` list of the squash
     subjects beneath; `Info.plist` is stamped;
   - opens `chore(release): X.Y.Z` as a PR, waits for the checks, squash-merges
     it and tags the merge commit `vX.Y.Z`;
   - builds, signs, notarizes, packages the DMG, and publishes the GitHub
     release with the prose only (`Scripts/release-notes.sh`) plus a "Full
     changelog" link, uploading the DMG, its checksum and the signed
     `appcast-entry.xml`, and records a build-provenance attestation for the
     DMG (Sigstore-signed, stored on the repo's Attestations page, verifiable
     with `gh attestation verify Bocan.dmg --repo bocan/bocan-music`);
   - pings the Homebrew tap. The Website workflow then assembles the Sparkle
     feed from every release's `appcast-entry.xml` (`Scripts/build-appcast.sh`)
     on top of the frozen history in `website/appcast/` and redeploys the site.
     Nothing is ever committed to `main` by CI.
3. To rebuild an existing version without retagging, run the workflow with
   the tag as input; `prepare` is skipped.

Version rule (`Scripts/release.sh`, tested by `make test-scripts`): a `!` or
`BREAKING CHANGE` gives major, `feat` minor, `fix` or `perf` patch; anything
else only (`chore`, `docs`, `ci`, ...) means there is nothing to release and
the workflow stops. An empty `Unreleased` also stops it: a release without
notes is a bug.

The `prepare` job needs the `RELEASE_TOKEN` secret, a fine-grained PAT with
Contents and Pull requests read/write on this repository, because a PR opened
with the default `GITHUB_TOKEN` gets no checks and branch protection requires
them.

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
| `DEVELOPER_ID_IDENTITY` | Name of the Developer ID signing identity that `codesign` uses |
| `SPARKLE_ED_PRIVATE_KEY` | EdDSA private key that signs the Sparkle update entry |
| `HOMEBREW_TAP_TOKEN` | Token that lets the workflow tell the Homebrew tap about a new release |
| `RELEASE_TOKEN` | PAT for the `prepare` job (see "Releasing" above) |
| `ACOUSTID_API_KEY`, `BOCAN_LASTFM_API_KEY`, `BOCAN_LASTFM_SHARED_SECRET`, `PODCAST_INDEX_API_KEY`, `PODCAST_INDEX_API_SECRET` | The service keys built into the release app (the same keys as in "Local developer API keys" below) |

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
| **Minimum macOS** | macOS 15 | `project.yml` sets `deploymentTarget: macOS 15.0`. Development requires Xcode 27 (and therefore a Mac running macOS 27), but the built app runs on macOS 15+. |
| **Architecture** | arm64 only | The project's FFmpeg and `fpcalc` builds are configured for arm64 only (`--arch=arm64` in `Scripts/build-ffmpeg-lgpl.sh`, `CMAKE_OSX_ARCHITECTURES=arm64` in `Scripts/build-fpcalc.sh`). TagLib, LAME, Opus and OpenSSL come from arm64 Homebrew (`/opt/homebrew`), and TagLib's keg path is hardcoded in `Modules/Metadata/Package.swift` and `project.yml`. A universal binary would double CI build time and require rebuilding every bundled dylib as universal, for a shrinking x86_64 user base. |
| **Intel (x86_64)** | Not supported | If Intel support is ever wanted, the arm64-only restriction in `Scripts/build-release.sh` and `.github/workflows/release.yml` must be revisited, the two source builds given a second architecture, all bundled dylibs rebuilt with `lipo`, and the hardcoded `/opt/homebrew` paths made prefix-aware. |

### The smoketest workflow

Every build and test job runs on the macOS 27 image, so nothing there shows that the app starts on macOS 15 or 26. The `smoketest` workflow (`.github/workflows/smoketest.yml`) does: it starts a built app on `macos-15` and `macos-26` runners and fails when the app does not stay up, when a crash report appears, or when the bundled `fpcalc` makes no fingerprint. `Scripts/smoke-launch.sh` holds the checks, and it also prints the macOS version each bundled library was built for.

It is started by hand and gates nothing:

```sh
gh workflow run smoketest                    # the latest release
gh workflow run smoketest -f tag=v2.19.0     # one published release
gh workflow run smoketest -f ref=main        # build a branch, tag or SHA, then test it
```

A build from a ref is a Release build with the libraries embedded as the release does, but ad hoc signed and without the hardened runtime. The test proves that the app starts. It does not prove that every code path works on that macOS.

## Design docs

Architecture decision records are documented in [`docs/design-spec/`](docs/design-spec/README.md).
Start with `docs/design-spec/_standards.md`, then read the ADRs relevant to the area you are changing.

## FFmpeg (AudioEngine module)

The `AudioEngine` module decodes non-AVFoundation formats (OGG/Vorbis, Opus, DSD, APE, WavPack)
and all network streams via FFmpeg, through an in-tree `CFFmpeg` system
module that links FFmpeg dynamically.

### One FFmpeg, built by the project, under the LGPL

Every build links the same FFmpeg: the project's own source build, licensed
under the LGPL v2.1 or later (ADR-096). Debug, the test suites, all three CI
workflows and the release use it. Homebrew's `ffmpeg` is a GPLv3 build with
libx264 and libx265; it is not used, and it is not in the `Brewfile`.
Homebrew's `chromaprint` depends on it, so that is not used either (see
"fpcalc" below). If another tool installs Homebrew's `ffmpeg` on your
machine, that is harmless: no build setting looks at it, and
`RequiredCodecsTests` fails if one ever does.

Until 2026-10-02 the project linked Homebrew's FFmpeg, and every release up
to 2.19.0 shipped that GPLv3 build against the project's own rule. ADR-096
has the facts and the decisions.

### Setup

```bash
make ffmpeg-lgpl              # run automatically by make bootstrap
make doctor                   # checks the build is there and is LGPL
```

`make ffmpeg-lgpl` runs `Scripts/build-ffmpeg-lgpl.sh`, which:

1. Reads the version, the URL and the SHA-256 from `.ffmpeg-source`.
2. Downloads the tarball into `build/ffmpeg-src` and refuses a wrong
   checksum.
3. Configures, builds and installs into `build/ffmpeg-lgpl` (gitignored),
   for the app's deployment target, macOS 15.0.
4. Refuses the result unless `libavutil` reports "LGPL version 2.1 or
   later".

It is idempotent. The stamp file `build/ffmpeg-lgpl/.built-from` records the
pin, the configure line and the script; when none of them changed, the
script does nothing. The FFmpeg build itself took 34 seconds on an 18-core
machine.

The configure line is the `CONFIGURE_ARGS` array in that script, and the
rules for whoever edits it are in the script's header. In short:
`--enable-gpl` and `--enable-version3` never appear; decoders and demuxers
are not cut down to an allow-list; a new `--enable-lib*` needs the library's
licence named in the PR; and no `|| true` goes after the checksum check, the
build or the licence check. `--disable-autodetect` is there so that two
machines build the same library: without it, configure links whatever it
finds (libX11, libxcb and SDL2 on a machine that has them).

The build links these external libraries, all from Homebrew and all in the
`Brewfile`: `lame` (LGPL-2.0-or-later), `opus` (BSD-3-Clause) and
`openssl@3` (Apache-2.0). It also uses the system zlib and bzlib and Apple's
AudioToolbox. `NOTICES.md` carries the source link, the configure line and
the licences; regenerate it with `Scripts/gen-notices.sh` after a bump.

### How the packages find it

The package manifests name the FFmpeg prefix by path:
`Context.packageDirectory/../../build/ffmpeg-lgpl`. They do not use
pkg-config, on purpose. Xcode does not pass the shell environment to
SwiftPM, so a pkg-config lookup there finds Homebrew's FFmpeg when it is
installed. No `PKG_CONFIG_PATH` is needed for FFmpeg, locally or in CI.

- `AudioEngine`, `Playback`, `Scrobble`, `SyncServer` and `UI` each pass
  `-Xcc -I<prefix>/include`. Every package that loads the `CFFmpeg` module
  through `AudioEngine` needs it; without it the build fails with
  "libavcodec/avcodec.h file not found".
- `project.yml` names `$(SRCROOT)/build/ffmpeg-lgpl` for the Xcode build.
- No manifest and no line of `project.yml` names the shared
  `/opt/homebrew/include` or `/opt/homebrew/lib`. Those directories also
  hold Homebrew's FFmpeg when it is installed, and the build would take it
  silently. TagLib is named by its own keg (`/opt/homebrew/opt/taglib/...`).

`FFMPEG_PREFIX` overrides the path for command-line builds: the build
script, `Scripts/build-fpcalc.sh`, `Scripts/embed-deps.sh`, `make doctor`
and the package manifests under `swift build` and `swift test` all read it.
An Xcode build does not see it, for the reason above.

**Git worktrees.** A worktree has its own, empty `build/`. Run `make
ffmpeg-lgpl` in it before anything that links `AudioEngine`, or, for
command-line builds only, point `FFMPEG_PREFIX` at an existing build.

### The source pin, and how to bump FFmpeg

`.ffmpeg-source` pins the exact release: `FFMPEG_VERSION`, `FFMPEG_URL` and
`FFMPEG_SHA256`. To move to another release:

1. Change the three values in `.ffmpeg-source`. Confirm the SHA-256 against
   a second source before you commit it.
2. Read `LICENSE.md` in the new tarball; do not assume it matches the old
   one.
3. Run `make ffmpeg-lgpl`, then `make bundle-fpcalc` (it regenerates the
   Xcode project itself; run `make generate` too if dylib file names
   changed).
4. Run the full test suites; decoder APIs move between releases.
   `RequiredCodecsTests` is the list of what FFmpeg must provide.
5. Regenerate `NOTICES.md` with `Scripts/gen-notices.sh`, and update the
   source link in `website/src/_data/credits.json`.

`make doctor` (run in the PR and branch workflows too) fails via
`Scripts/check-ffmpeg-build.sh` when the build is missing, when it does not
report "LGPL version 2.1 or later", or when the `fpcalc` dylibs in
`Resources/` come from different library majors than the build. The check's
tests are hermetic (`Scripts/tests/check-ffmpeg-build-test.sh`, run by `make
test-scripts`, on Linux in CI).

### What proves the licence

- `RequiredCodecsTests` (`Modules/AudioEngine/Tests/AudioEngineTests/`) asks
  the linked FFmpeg for every decoder, demuxer, protocol, encoder and muxer
  the app relies on, and asserts the licence string. It fails against
  Homebrew's build on the licence alone.
- `make check-licence APP=path/to/Bocan.app` runs
  `Scripts/check-bundle-licence.sh`, the release gate. It fails unless every
  FFmpeg library in the bundle reports "LGPL version 2.1 or later", no
  GPL-only library is in the bundle, and no binary loads FFmpeg from outside
  the bundle. `release.yml` runs it after `Scripts/embed-deps.sh` and before
  the signature check. Its tests are `Scripts/tests/check-bundle-licence-test.sh`.

### CI

`branch.yml`, `pr.yml` and `release.yml` run `brew bundle`, then `make
ffmpeg-lgpl`, from a cache of `build/ffmpeg-lgpl` and `build/chromaprint`
keyed on the two pin files and the two build scripts. The cache has no
restore keys, so a build from another pin or another configure line is never
reused.

### Building AudioEngine outside Xcode

```bash
make ffmpeg-lgpl              # once per checkout or worktree
cd Modules/AudioEngine
swift build
swift test
# or simply, from the repo root:
make test-audio-engine
```

### Key Swift concurrency decisions

| Pattern | Reason |
|---------|--------|
| `@preconcurrency import AVFoundation` | `AVAudioPCMBuffer` lacks `Sendable`; suppress cascade errors |
| `EngineGraph: @unchecked Sendable` class (not actor) | `AVAudioPlayerNode` can't cross actor boundaries; safety ensured by owning `AudioEngine` actor |
| `nonisolated public let state` | `AsyncStream` is `Sendable`; `let` is immutable so `nonisolated` is safe |



## fpcalc / AcoustID fingerprinting

Bòcan uses [Chromaprint](https://acoustid.org/chromaprint) (`fpcalc`) to generate acoustic fingerprints for track identification via the AcoustID API. `fpcalc` and all of its FFmpeg dylib dependencies must be bundled inside the app bundle with paths rewritten to `@loader_path`: the Debug build runs in the macOS sandbox and cannot reach Homebrew at all, and the shipped release build (unsandboxed, see CLAUDE.md) must not depend on Homebrew being installed on the user's Mac.

### Why the binaries are not in the repo

`fpcalc` needs 10 dylibs: `libchromaprint`, the four FFmpeg libraries (`libavcodec`, `libavformat`, `libavutil`, `libswresample`), `libssl`, `libcrypto`, `libmp3lame`, `libopus`, and `libmpg123` (Homebrew's `lame` links it). Storing those in git would bloat every clone. Instead, `Scripts/build-fpcalc.sh` builds and bundles them locally and in CI.

### Why fpcalc is built from source

Homebrew's `chromaprint` depends on Homebrew's `ffmpeg`, which is a GPLv3 build (ADR-096). So the project builds Chromaprint itself, from the release pinned in `.chromaprint-source` (`CHROMAPRINT_VERSION`, `CHROMAPRINT_URL`, `CHROMAPRINT_SHA256`), against the project's LGPL FFmpeg. `fpcalc` and the app then use the same FFmpeg. Apple's vDSP does the FFT, so no FFT library is linked. Fingerprints of five tracks were identical to those from the Homebrew `fpcalc`.

### Setup (done automatically by `make bootstrap`)

```bash
# Requires: brew bundle  (cmake, lame, opus, openssl@3)
make bundle-fpcalc
```

This runs `Scripts/build-fpcalc.sh`, which:

1. Builds the LGPL FFmpeg if it is not there (`Scripts/build-ffmpeg-lgpl.sh`).
2. Downloads the pinned Chromaprint source, refuses a wrong checksum, and builds `fpcalc` and `libchromaprint` with CMake into `build/chromaprint`. This step is skipped when that build is up to date.
3. Empties `Resources/` of the previous `fpcalc` and dylibs, so a dylib that is no longer needed cannot stay behind and ship.
4. Copies `fpcalc` and, recursively, every dylib it needs that is not a system library into `Resources/`, and rewrites each reference to `@loader_path/<name>`.
5. Ad-hoc signs every binary (sufficient for Debug builds; release builds use a real Developer ID identity via `$SIGNING_IDENTITY`).

`make bundle-fpcalc` then runs `xcodegen generate`, so XcodeGen adds the new files in `Resources/` to the bundle.

### Re-running after an FFmpeg or Chromaprint bump

```bash
make bundle-fpcalc   # rebuilds what changed, re-bundles all dylibs, then regenerates the Xcode project
```

Run it whenever `.ffmpeg-source` or `.chromaprint-source` changes.
`bundle-fpcalc` runs `xcodegen generate` itself, so the project picks up
renamed dylibs (e.g. `libavcodec.62` to `libavcodec.63`) automatically. If
the dylibs in `Resources/` come from different library majors than the
FFmpeg build, `make doctor` (and CI) fails; see "The source pin, and how to
bump FFmpeg" above. After a Chromaprint bump, compare the fingerprint of
one track before and after.

### CI

The CI workflows (`pr.yml`, `branch.yml`, `release.yml`) do not install Homebrew's `ffmpeg` or `chromaprint`; neither is in the Brewfile. A dedicated step runs `make bundle-fpcalc` before `make generate` so all dylibs are present when XcodeGen scans `Resources/`.

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
  is `PlayerNode → TimePitch → EQ → BassBoost → Crossfeed →
  StereoExpander → Limiter → Mixer → Output`; every node is always present,
  and each one can be bypassed except the limiter, which never is. See `Modules/AudioEngine/Sources/AudioEngine/DSP/DSPChain.swift`.
  ReplayGain is not in the chain: it is applied per track inside the buffer
  pump, so a crossfade keeps each track at its own level (#573).
- **Anti-pop fades.** The engine ramps `AVAudioPlayerNode.volume` over ~10 ms
  before any operation that truncates playback mid-cycle (`stop`, `pause`,
  `seek`, track-change). This is a separate gain stage from the user-volume
  mixer and the per-track ReplayGain in the pump; do not collapse them.
- **`make bundle-fpcalc`.** Rebuild and re-bundle `fpcalc` and its FFmpeg
  dylibs whenever `.ffmpeg-source` or `.chromaprint-source` changes (a new
  FFmpeg release can rename a dylib, e.g. `libavcodec.61` → `libavcodec.62`).
  Homebrew upgrades no longer change the FFmpeg the project links. The
  script also re-signs the binaries with the ad-hoc identity; pass
  `SIGNING_IDENTITY` for Developer-ID builds.
- **Thread Sanitizer on the test action.** `Scripts/patch-scheme.sh` is run
  by `xcodegen` (via `postGenCommand`) to enable TSan in the generated
  scheme, because XcodeGen has no first-class flag for it.
