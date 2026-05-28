# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project at a glance

Bòcan is a native macOS music player (SwiftUI + Swift 6, macOS 15+, arm64 only). The codebase is a multi-module SPM workspace plus an Xcode shell app. There is no Catalyst, no Electron, no cross-platform layer.

## Build, test, lint

All everyday commands go through the top-level `Makefile`. Run `make help` for the full list. The ones that come up most:

| Task | Command |
|------|---------|
| Bootstrap a fresh clone (brew, hooks, bundle fpcalc) | `make bootstrap` |
| Regenerate `Bocan.xcodeproj` from `project.yml` | `make generate` |
| Debug build | `make build` |
| Unit + integration tests (Xcode bundle, excludes UI snapshots) | `make test` |
| Coverage gate (CI gate, fails < 80%) | `make test-coverage` |
| Per-module SPM tests | `make test-<module>` (e.g. `test-ui`, `test-audio-engine`, `test-persistence`, `test-playback`, `test-scrobble`, `test-metadata`, `test-library`, `test-acoustics`) |
| Per-module coverage with module-level floors | `make coverage-all` |
| Lint (strict — CI gate) | `make lint` |
| Auto-format | `make format` |
| Open in Xcode | `make open` |
| Doctor (tool versions, env sanity) | `make doctor` |

Per-module SPM tests use `swift test` under the module directory. To run a single test or suite, `cd Modules/<Name>` and use `swift test --filter <Suite>` or `--filter <Suite>/<testName>`.

**The Xcode `BocanTests` target runs without a host app (`TEST_HOST = ""`), so AppKit / SwiftUI rendering is unavailable there.** Snapshot tests and anything that needs a real view tree live in the `UI` SPM package and run via `make test-ui`. `make test` will appear to "miss" them — that's by design, not a bug to chase.

## Architecture

Strict module DAG, no upward imports:

```
Observability → Persistence → AudioEngine, Metadata, Library, Playback, Scrobble, Subsonic, Acoustics → UI → App
```

| Module | Owns |
|--------|------|
| `Observability` | `AppLogger`, MetricKit listener, log redaction. Never `print`, never raw `os_log` — always go through `AppLogger`. |
| `Persistence` | GRDB 7 schema + numbered migrations under `Sources/Persistence/Migrations/`, typed repositories, FTS5 search, `ValueObservation` streams. WAL mode. |
| `AudioEngine` | `AudioEngine` actor, `EngineGraph` (`AVAudioPlayerNode`-backed), `BufferPump`, the AVFoundation + FFmpeg decoder split (`AVFoundationDecoder`, `FFmpegDecoder`, `DecoderFactory`, `FormatSniffer`), DSP chain, `SubsonicStreamCache`. |
| `Metadata` | TagLib read/write, cover-art extraction, LRC parsing. |
| `Library` | Folder scanner, FSEvents watcher, conflict resolver, cover-art cache. |
| `Playback` | `QueuePlayer` actor, queue/history/shuffle, `GaplessScheduler`, `CrossfadeScheduler`, `PlayableSource` (`.localBookmark` / `.subsonic` / `.internetRadio`), MPNowPlaying, sleep timer, queue persistence v1→v2. |
| `Scrobble` | Last.fm / ListenBrainz / Rocksky providers + an offline-resilient `ScrobbleService` queue. |
| `Subsonic` | `SubsonicService` actor wrapping the `SwiftSonic` client; capability detection (advertised + legacy-core probe); Keychain credentials. |
| `Acoustics` | Chromaprint fingerprinting + AcoustID + MusicBrainz lookup. |
| `UI` | All SwiftUI views, view models (`LibraryViewModel` is the spine), settings, mini player, snapshot tests. Only module that imports AppKit. |

Cross-cutting standards live in `docs/design-spec/_standards.md` — read this if you're about to add anything substantial. Implementation phases live alongside as `phase-NN-*.md`.

## Things easy to get wrong

- **`Bocan.xcodeproj` is generated from `project.yml` via XcodeGen.** Do not hand-edit `project.pbxproj`. If a build setting needs changing, edit `project.yml` and run `make generate`.
- **FFmpeg is dynamically linked via Homebrew**, not vendored. The `AudioEngine` module won't build outside Xcode without `PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig`. `make test-audio-engine` handles it; raw `swift build` from `Modules/AudioEngine` does not.
- **`fpcalc` and its FFmpeg dylibs are not in git.** `make bundle-fpcalc` copies them from Homebrew into `Resources/` with paths rewritten to `@loader_path/…`. Re-run after any FFmpeg major version bump (e.g. `libavcodec.61` → `.62`); `make generate` only needs re-running if dylib filenames changed.
- **Sandbox is on, hardened runtime is on.** Entitlements get added per-feature, not "just in case". File access goes through the `SecurityScope` helper — never raw `URL.startAccessingSecurityScopedResource()` scattered around.
- **`AVAudioFile` snapshots a file's length at open time.** It's the wrong decoder for live streams (Subsonic internet radio, etc.). `DecoderFactory.make(for:)` routes HTTP/HTTPS URLs to `FFmpegDecoder` for this reason; new playback paths need to honour the same split.
- **`SubsonicStreamCache` waits for the full download before signalling readiness**, by deliberate design — `AVAudioFile`'s snapshot semantics meant the previous "stream while downloading" path silently truncated tracks to whatever bytes happened to be on disk at open. Don't reintroduce mid-download signalling without also swapping the decoder for a streaming-aware one.
- **Capability snapshots are persisted per-Subsonic-server**, but `loadCapabilities` is only auto-invoked from the bootstrap fan-out in `BocanApp.swift` and from the Settings "Test Connection" path. Sidebar rows are gated on the persisted JSON; if a server upgrade exposes a new capability and nothing kicks a refresh, the row won't appear until the cache ages past `freshnessInterval` (24 h).
- **`PlayableSource` is `Codable`** with a discriminator key. The `QueuePersistence` v1→v2 migration depends on this; new cases need both encode/decode arms and existing-test updates.
- **No upward imports**. The dependency order above is enforced — if you find yourself wanting to `import UI` from `Playback`, the abstraction is in the wrong layer.

## Concurrency, errors, logging

- Swift 6 strict concurrency. Long-lived state is owned by `actor`s, not classes with locks. SwiftUI view state is `@MainActor`. `Task.checkCancellation()` inside any long loop.
- Each module has a single `*Error: Error, Sendable` enum carrying context (URL, underlying error, reason) — not bare cases.
- `AppLogger` facade only. Categories: `app`, `audio`, `library`, `metadata`, `persistence`, `ui`, `network`, `playback`, `cast`, `scrobble`, `subsonic`. Standard pattern: `log.debug("op.start", […])` / `log.debug("op.end", ["ms": …])` / `log.error("op.failed", ["error": String(reflecting: err)])`. Keys in `Observability.sensitiveKeys` are redacted automatically.
- No `print`, no raw `os_log`, no `try?` without an `else { log.warning }` companion, no `fatalError` outside `#if DEBUG` or truly-unreachable `default:`.
- **Tests must not hit the network.** Stub via `URLProtocol` or a protocol-based HTTP client mock. Fixtures live in `Tests/Fixtures/` at repo root and are checked-in, not generated at test time.

## Commits

Document new features in README.md and in the repo's /website pages. NEVER use em dashes (—) in commit messages or markdown, or the website.
After any logical change, run `make format`, `make lint` and `make test-coverage` to ensure standards are met before committing.
Use Conventional Commits, scope = module: `feat(audio): …`, `fix(subsonic): …`, `chore(deps): …`. One logical change per commit / PR. The pre-commit hook (`make install-hooks`, also run automatically by `make bootstrap`) runs SwiftFormat in lint mode + SwiftLint strict; CI re-runs both. Don't `--no-verify` past failures; fix the issue.

## When in doubt

- `docs/design-spec/_standards.md` — the engineering charter, binding on all new code.
- `docs/design-spec/phase-NN-*.md` — historical context for major subsystems; the phase number often hints at why a particular boundary exists.
- `DEVELOPMENT.md` — environment setup, FFmpeg / fpcalc details, secrets layout.
- `CONTRIBUTING.md` — commit / PR conventions.
