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
| Per-module SPM tests | `make test-<module>` (one per module: `test-observability`, `test-persistence`, `test-metadata`, `test-library`, `test-acoustics`, `test-audio-engine`, `test-playback`, `test-scrobble`, `test-subsonic`, `test-podcasts`, `test-sync-server`, `test-ui`) |
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
Observability → Persistence → AudioEngine, Metadata, Library, Playback, Scrobble, Subsonic, Acoustics, Podcasts, SyncServer → UI → App
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
| `Acoustics` | Chromaprint fingerprinting + AcoustID, the single `MusicBrainzClient` (recording, artist, release-group; one shared 1 req/s limiter for the whole app) and `WikipediaClient`. |
| `Podcasts` | FeedKit-based RSS/Atom feed refresh, Podcast Index + iTunes search, subscriptions, episode downloads and retention, Podcasting 2.0 extras (chapters, transcripts, persons, podroll). |
| `SyncServer` | Phone Sync (ADR-060 to ADR-070): `ServerIdentity` (self-signed P-256 login-Keychain TLS identity), `TrustedDevices` trust store, and, in later slices, the Bonjour-advertised mutual-TLS server that serves a manifest + files read-only to a paired phone. Separate identity/port from any ADR-034 remote control. |
| `UI` | All SwiftUI views, view models (`LibraryViewModel` is the spine), settings, mini player, snapshot tests. Only module that imports AppKit. |

Cross-cutting standards live in `docs/design-spec/_standards.md` — read this if you're about to add anything substantial. Architecture decision records live alongside as `ADR-NNN-*.md`.

## Things easy to get wrong

- **`Bocan.xcodeproj` is generated from `project.yml` via XcodeGen.** Do not hand-edit `project.pbxproj`. If a build setting needs changing, edit `project.yml` and run `make generate`.
- **FFmpeg is dynamically linked via Homebrew**, not vendored. The `AudioEngine` module won't build outside Xcode without `PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig`. `make test-audio-engine` handles it; raw `swift build` from `Modules/AudioEngine` does not.
- **`fpcalc` and its FFmpeg dylibs are not in git.** `make bundle-fpcalc` copies them from Homebrew into `Resources/` with paths rewritten to `@loader_path/…`. Re-run after any FFmpeg major version bump (e.g. `libavcodec.61` → `.62`); `make generate` only needs re-running if dylib filenames changed.
- **The Xcode (Debug) build is sandboxed; the shipped release build is not.** Both carry the hardened runtime. `Resources/Bocan.entitlements` applies to Debug only; the CI release build is deliberately re-signed without entitlements by `Scripts/embed-deps.sh`, so `/Applications/Bocan.app` runs unsandboxed. Consequences: the two builds use **different libraries** (Debug: `~/Library/Containers/io.cloudcauldron.bocan/Data/Library/Application Support/Bocan/`; release: `~/Library/Application Support/Bocan/`) and different preferences, so a debug run never touches the real library, and numbers read from one say nothing about the other. Before quoting anything from "the library", `lsof -p $(pgrep -x Bocan)` and query the file the running app actually has open. Entitlements for Debug get added per-feature, not "just in case", and file access still goes through the `SecurityScope` helper (it is a no-op outside the sandbox), never raw `URL.startAccessingSecurityScopedResource()` scattered around.
- **`AVAudioFile` snapshots a file's length at open time.** It's the wrong decoder for live streams (Subsonic internet radio, etc.). `DecoderFactory.make(for:)` routes HTTP/HTTPS URLs to `FFmpegDecoder` for this reason; new playback paths need to honour the same split.
- **`SubsonicStreamCache` waits for the full download before signalling readiness**, by deliberate design — `AVAudioFile`'s snapshot semantics meant the previous "stream while downloading" path silently truncated tracks to whatever bytes happened to be on disk at open. Don't reintroduce mid-download signalling without also swapping the decoder for a streaming-aware one.
- **Capability snapshots are persisted per-Subsonic-server**, but `loadCapabilities` is only auto-invoked from the bootstrap fan-out in `BocanApp.swift` and from the Settings "Test Connection" path. Sidebar rows are gated on the persisted JSON; if a server upgrade exposes a new capability and nothing kicks a refresh, the row won't appear until the cache ages past `freshnessInterval` (24 h).
- **`PlayableSource` is `Codable`** with a discriminator key. The `QueuePersistence` v1→v2 migration depends on this; new cases need both encode/decode arms and existing-test updates.
- **Context7 Lookups**. With Context7 lookups, ALWAYS choose the latest version of a dependency (FeedKit, GRDB, etc.) and avoid any deprecated APIs. Where the spec deviates from this, stop and ask for clarification before proceeding. This is as important as any other spec detail, and will save us from wasted work.
- **No upward imports**. The dependency order above is enforced — if you find yourself wanting to `import UI` from `Playback`, the abstraction is in the wrong layer.
- **All user-facing copy MUST be localized. No bare user-facing string literals, under any circumstances.** Every user-visible string in the `UI` module routes through the `L10n` helper (`Text(localized:)` / `L10n.string`) with a key in `Modules/UI/Sources/UI/Resources/Localizable.xcstrings`; a bare literal compiles, renders in English, and silently never localizes. The `no_bare_user_facing_literal` SwiftLint rule (module-wide, CI gate) and the `L10nTests` suite enforce this. After adding or changing catalog keys, run `make pseudolocale` (the en-XA coverage test fails otherwise). Strings displayed by the UI but owned by lower modules (preset names, status labels) keep English raw values and get a UI-side display mapping. New user-facing surfaces belong in the `UI` module where the catalog and guard cover them; do not add user-facing literals to `App/` (it has no String Catalog). Full workflow: `docs/design-spec/localization.md`.

## Concurrency, errors, logging

- Swift 6 strict concurrency. Long-lived state is owned by `actor`s, not classes with locks. SwiftUI view state is `@MainActor`. `Task.checkCancellation()` inside any long loop.
- Each module has a single `*Error: Error, Sendable` enum carrying context (URL, underlying error, reason) — not bare cases.
- `AppLogger` facade only. Categories: `app`, `audio`, `library`, `metadata`, `persistence`, `ui`, `network`, `playback`, `podcasts`, `scrobble`, `subsonic`, `sync`. Standard pattern: `log.debug("op.start", […])` / `log.debug("op.end", ["ms": …])` / `log.error("op.failed", ["error": String(reflecting: err)])`. Keys in `Observability.sensitiveKeys` are redacted automatically.
- No `print`, no raw `os_log`, no `try?` without an `else { log.warning }` companion, no `fatalError` outside `#if DEBUG` or truly-unreachable `default:`.
- **Tests must not hit the network.** Stub via `URLProtocol` or a protocol-based HTTP client mock. Fixtures live in `Tests/Fixtures/` at repo root and are checked-in, not generated at test time.

## Schema discipline

- A migration may only add a column or table if the same phase also adds code that WRITES it, code that READS it, and a test asserting real (non-null, non-default) values land in it.
- No speculative fields "for later". If a future phase needs a column, that phase adds the migration.
- Maintain `docs/data-dictionary.md`: every column lists "written by", "read by", and the spec requirement it traces to. A blank cell fails the phase. The tables are generated (`make data-dictionary`); the reviewed content goes in `docs/data-dictionary-notes.json`, keyed `table.column`, and a new column is not done until it has a `traces` entry there.
- Definition of Done includes: `make audit-db` passes without significant findings (see DEVELOPMENT.md; it audits a copy of the real library, so run it against your own).

## Branching (trunk-based, short-lived branches)

`main` is the trunk and is never committed to directly, by the maintainer or by Claude. Every piece of work, however small, happens on a short-lived branch:

- Start from an up-to-date trunk: `git switch main && git pull --ff-only`, then `git switch -c <type>/<slug>`.
- Name: `<type>/<short-kebab-slug>`, where `<type>` is the Conventional Commit type the work will carry (`feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, `ci/`) and the slug is a few words, optionally with the issue number: `fix/349-album-grid-scroll-restore`, `feat/phone-sync-manifest`.
- One logical change per branch, lived for hours or a day or two, not weeks. If a task turns out to have two logical changes, make two branches.
- Commit to the branch as slices go green (see Commits below). Push the branch whenever the user asks or a slice is done; branch pushes run only the light CI (lint, format, build, secret scan), so pushing is cheap.
- Land it with a pull request into `main`. The full CI suite runs on the PR, not on the branch push. After the merge, delete the branch and switch back to `main`.
- Before any git surgery, check `git branch --show-current`; if it says `main` and there are uncommitted changes, move them to a branch (`git switch -c ...` carries them across) rather than committing on trunk.

## Commits

Document new features in README.md and in the repo's /website pages. NEVER use em dashes (—) in commit messages or markdown, or the website.
After any logical change, run `make format`, `make lint`, `make build` and `make test-coverage` to ensure standards are met before committing.
Use Conventional Commits, scope = module: `feat(audio): …`, `fix(subsonic): …`, `chore(deps): …`. One logical change per commit / branch / PR. The pre-commit hook (`make install-hooks`, also run automatically by `make bootstrap`) runs SwiftFormat in lint mode + SwiftLint strict; CI re-runs both. Don't `--no-verify` past failures; fix the issue.

## When in doubt

- `docs/design-spec/_standards.md` — the engineering charter, binding on all new code.
- `docs/design-spec/ADR-NNN-*.md` — historical context for major subsystems; the ADR number often hints at why a particular boundary exists.
- `DEVELOPMENT.md` — environment setup, FFmpeg / fpcalc details, secrets layout.
- `CONTRIBUTING.md` — commit / PR conventions.
