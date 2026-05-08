# Bòcan Music

[![CI](https://github.com/bocan/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/ci.yml)
[![CodeQL](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![Xcode 26](https://img.shields.io/badge/Xcode-26-1575F9)

A native macOS music player built the old-fashioned way — no Catalyst, no Electron, no cross-platform abstractions. Swift 6 strict concurrency, SwiftUI, GRDB, AVFoundation, and FFmpeg under the hood; every module ships its own test suite.

![Bòcan — Songs view](website/static/screenshots/Screenshot%202026-05-07%20at%2020.35.08.png)

## On the name

**Bòcan** (Scottish Gaelic, roughly *BAW-khan*) is a hobgoblin — the household spirit that curates your music library while you sleep. See [spec.md](spec.md) for the full etymology; the short version is that computers don't like `ò`, so the binary, bundle, and repository all use `bocan`.

---

## What Bòcan can do right now

### Formats

- Plays every format AVFoundation knows about out of the box: **FLAC, ALAC, AAC, MP3, WAV, AIFF, CAF, M4A**.
- Also plays **Ogg Vorbis, Opus, APE (Monkey's Audio), WavPack, and DSD** via a fully-integrated FFmpeg bridge — the formats every other Mac player makes you install a plug-in for.
- Embedded cover art is extracted from all supported containers and displayed everywhere.

### Playback

- **True gapless playback** — a pre-decoded secondary `AVAudioPlayerNode` is primed during the last seconds of every track and handed off with nanosecond `AVAudioTime` anchoring. No click, no silence, no crossfade required.
- **Configurable crossfade** — smooth volume-ramp transitions between consecutive tracks, fully integrated into the gapless scheduler. Set anywhere from 0 to 12 seconds in Preferences.
- **Playback speed control** (0.5× – 2.0×) with pitch correction, accessible from the transport bar.
- **Sleep timer** — set a countdown from 5 minutes to 3 hours; Bòcan fades gracefully to silence rather than cutting mid-song.
- **Shuffle** — full Fisher–Yates randomisation with smart/weighted mode that avoids recent repeats.
- **Repeat** — Off / Repeat All / Repeat One, cycling from a single button.
- **Stop after current track** — finish the song, then halt. Exactly what it says on the tin.
- Full **queue** with history; skip forward, skip backward through real playback history.
- **Launch resume** — now-playing state is persisted across launches; Bòcan restores the track and seeks to where you left off (paused, ready to continue).

### Library management

- **Folder-based library** rooted at one or more user-chosen directories or individual files; security-scoped bookmarks keep the sandbox happy.
- **Full + incremental scan** — the first scan indexes everything; subsequent scans use mtime + file-size change detection so unchanged files are skipped in milliseconds.
- **Live FSEvents watcher** — after each scan Bòcan watches every library root for file-system changes and automatically re-imports any supported audio file that is created or modified. Toggled by the "Watch folders for new files" preference in Library settings.
- **Add Files / Add Folder** pickers available from the File menu and from Library settings.
- **Deduplication** at file-fingerprint level — importing the same file twice doesn't create duplicates.
- **Quit guard** — if a library scan or ReplayGain analysis is running when you quit, Bòcan shows a contextual confirmation alert rather than abandoning the operation silently.
- **Tag-aware change detection** — when you edit tags in an external app, the next scan picks up the change. When you edit tags *in* Bòcan, a `user_edited` flag prevents a rescan from overwriting your work.
- Cover art is cached in a content-addressed store under `~/Library/Application Support` so artwork loads instantly.

### Metadata editing

- **In-app tag editor** — edit title, artist, album, track number, disc number, year, genre, composer, comment, and BPM for a single track or a batch selection simultaneously.
- **Multi-track editing** with a "changed fields only" diff: blank a field in the sheet and it is left untouched on every selected track; fill it in and it is written to all of them.
- **Embedded cover art editor** — drag-and-drop a new image, paste from the clipboard, or fetch from the network. Crop to square before saving.
- **Automatic cover art fetching** from MusicBrainz / Cover Art Archive, with a rate-limiter to stay inside the API terms.
- Writes are atomic (file then database then cache, with a rollback ring for the last *N* edits).
- Undo support — the original tags are preserved in a backup ring; one click reverts.
- Writes use **ID3v2.4** on MP3 and format-native tag containers everywhere else via TagLib.

### AcoustID fingerprinting & auto-tagging

- **Acoustic fingerprinting** via a bundled Chromaprint / fpcalc binary — no extra install required.
- Submits fingerprints to [AcoustID](https://acoustid.org) and resolves matches against **MusicBrainz** to retrieve title, artist, album, year, track number, and ISRC.
- Results open in a **per-field confirmation sheet**: each candidate expands to show every tag (title, artist, album artist, album, genre, track #, disc #, year) with the **current value beside the proposed value** and a tickbox per field. Fields where the candidate matches what you already have are pre-disabled; fields that would change are pre-ticked. Hit "Apply Selected" and only the boxes you ticked are written — the rest are left untouched.
- Sliding-window rate limiting keeps both the AcoustID (3 req/s) and MusicBrainz (1 req/s) APIs happy.

### DSP & audio effects

- **10-band graphic EQ** at ISO standard centre frequencies (31 Hz – 16 kHz), ±12 dB per band, with global bypass and A/B compare.
- **Bass boost** — a decoupled low-shelf stage so it doesn't muddy your EQ presets.
- **Stereo expander** — mid/side matrix with continuously variable width from mono (0.5×) to wide (2.0×).
- **Binaural crossfeed** — Bauer stereo-to-stereo matrix for headphone listening; tames fatiguing hard-panned mixes.
- **Peak limiter** — always-on soft brickwall at −0.3 dBFS to catch post-EQ clipping.
- **EQ presets** — built-in presets (Flat, Rock, Classical, Vocal, Bass Boost…) plus unlimited user-defined presets, persisted in the database.
- **ReplayGain** — reads existing `REPLAYGAIN_TRACK_GAIN` / `REPLAYGAIN_ALBUM_GAIN` tags and applies them at playback time; analyses and writes tags for tracks that don't have them (EBU R128 K-weighted loudness).
- **Per-track / per-album / global EQ** assignment stored in the database.

### Visualisers

- **Three real-time visualisers** driven by the live audio stream: a **spectrum bars** FFT display, a classic **oscilloscope** waveform, and a **fluid Metal** GPU shader that reacts to the music's energy.
- A built-in **visualiser pane** docks beside Now Playing; **⌘⇧F** breaks it out into a dedicated fullscreen window for parties and lean-back listening.
- **Sensitivity control** (0.1×–3.0×) and an **FPS cap** (30 / 60 / unlimited) let you trade detail for battery — settings persist via `AppStorage`.
- Tap-anywhere mode switching between visualisers; the active mode is remembered between launches.

### Playlists & playlist I/O

- **Manual playlists** with drag-and-drop reordering, nestable folders, and SQLite-backed persistence.
- **Smart playlists** built from a rule editor (artist / album / genre / play-count / date-added / rating predicates, AND/OR groups) compiled to live SQL — results update automatically as your library changes.
- **Import** `.m3u`, `.m3u8`, `.pls`, and `.xspf` playlists via **File ▸ Import Playlist…** (⇧⌘O). Track resolution tries an exact path match first, then falls back to fuzzy artist/title/duration matching against your library.
- **Export** any manual playlist via the sidebar context menu — choose `.m3u8`, `.m3u`, `.pls`, or `.xspf`, with **absolute** or **relative-to-folder** path mode for portable exports.
- **CUE sheets** are recognised at scan time and exposed as virtual tracks (per-track playback offsets are still on the way).

### Scrobbling

- **Last.fm and ListenBrainz** support, running side-by-side or independently — connect either or both from the **Scrobbling** tab in Preferences.
- **Last.fm desktop auth** flow: Bòcan opens the auth page in your browser and polls until you grant access; the session key lands in the macOS **Keychain**. **ListenBrainz** uses a personal user token (also Keychain-stored). Tokens are never written to disk or logs.
- **Classic eligibility rule**: a play is scrobbled when the track is at least 30 s long *and* you've heard ≥ 50 % of it or ≥ 4 minutes — whichever comes first. Time spent paused doesn't count.
- **Now-playing** pings on track start, throttled to one per 5 s so a fast skipper can't spam either service.
- **Offline-resilient queue** — plays are persisted to SQLite and drained by per-provider workers with exponential backoff; reachability changes wake the workers automatically. Duplicates are blocked by a `(track_id, played_at)` unique constraint.
- **Dead-letter handling**: rows that fail permanently (or exhaust retries) are surfaced in Settings with **Retry failed** and **Discard failed** buttons, alongside live counts of pending / failed / sent-today.
- Loved-track toggles round-trip to both providers (where the track has an MBID for ListenBrainz feedback).

### Browser & UI

- **Three-pane browser** — sidebar navigation, artist/album column browser, and a full track list.
- Dedicated **Albums grid**, **Tracks list**, **Recently Added**, and **Artists** views.
- **Sortable, filterable track table** — click any column header to sort; type to filter instantly.
- **Now Playing strip** along the bottom of every main view: artwork, title, artist, album, scrubber with timestamps, volume, transport, speed picker, sleep timer badge.
- The info (`ⓘ`) button in the transport opens the full tag editor for the current track in one click.
- **AirPlay routing** — an `AVRoutePickerView`-backed button in the Now Playing strip opens the system picker; a live route chip next to it shows the current output device (built-in speakers, HomePod, Apple TV, Bluetooth headphones…) and updates automatically when the device changes, including switches made from Control Centre.
- **Scan progress view** — during the initial library scan a dedicated progress pane shows what is being scanned; the browser becomes available the moment the first batch of tracks has been indexed.

### Mini Player

- **Three layouts in one window** — cycle between Strip (72 pt tall, just transport + scrubber), Compact (horizontal thumbnail + metadata + full controls), and Square (full-bleed artwork with an overlay gradient and controls).
- **Always-on-top mode** — pin the mini player above all other windows so it's never buried.
- **Full control parity** — every layout exposes prev/play-pause/next, scrubber, shuffle, repeat, stop-after-current, and the info button.
- Compact and Square layouts show **artist – album** below the track title.
- The info button on any mini-player layout **raises the main window** and opens the tag editor immediately — no manual window-switching required.
- Accent colour for toggle-button highlight respects the app's own colour palette (not just the macOS system accent).
- Long titles and artist names **scroll as marquee text** in the Strip and Compact layouts rather than truncating.
- Window size remembers your last drag; cycling layouts snaps back to sensible defaults (Strip 420×72, Compact 450×145, Square 310×310).

### Appearance & theming

- Full **light and dark mode** support across every view — all colours are semantic, no hard-coded values.
- **Custom accent colour** palette in Appearance preferences; applied consistently to sliders, toggle buttons, and interactive elements throughout the app and mini player.
- System colour scheme override — force Light, Dark, or follow System — per-app, not system-wide.

### Menu bar & notifications

- Optional **menu bar extra** with now-playing title and quick transport controls — hide or show it in General preferences.
- **On-track-change notifications** — a banner shows the artwork, title, and artist when a new track starts, silenced while the app is frontmost.
- **Dock tile** shows the current album artwork as a live badge.

### Data safety

- **Local backups** — Bòcan takes a rolling snapshot of its SQLite database on each launch (on by default). The number of snapshots to keep is configurable (default: 5); old ones are pruned automatically. A **Back Up Now** button and Finder reveal are in **Advanced preferences**.
- **iCloud Drive backup** (opt-in) — an automatic backup on launch copies the database to iCloud Drive, capped at 3 files to avoid runaway storage. Enable and manage it from **Advanced preferences**.

### Settings

- Full **Preferences window** (⌘,) with tabs: General, Library, Playback, DSP, Appearance, Advanced, About.
- **Library sources** are managed exclusively in the Library settings tab — add folders or individual files, remove any source, see full paths at a glance.
- All preferences are persisted via `UserDefaults` / `AppStorage`; changing them takes effect immediately without relaunch.

### Engineering

- **Seven SPM modules** with clean dependency boundaries: `Observability`, `AudioEngine`, `Persistence`, `Metadata`, `Library`, `Playback`, `UI`.
- **Swift 6 strict concurrency** throughout — `@MainActor` isolation, `Sendable` everywhere it matters, zero data races.
- **GRDB 7** persistence with typed repositories, explicit migrations, FTS5 full-text search, `ValueObservation`-based reactive streams, and WAL mode.
- **80% line-coverage gate** enforced in CI — the build fails if coverage drops.
- **SwiftLint + SwiftFormat** enforced on every commit via pre-commit hook and GitHub Actions.
- **CodeQL** on every PR and weekly (`security-and-quality` query pack).
- **Dependabot** monitoring all seven SPM manifests and every Actions workflow.
- **XcodeGen** project generation — no hand-edited `.pbxproj` files in the repo.
- Structured `os.Logger` logging with subsystem `io.cloudcauldron.bocan`; filterable in Console.app and Instruments.
- MetricKit integration for energy, hangs, and disk I/O telemetry.

---

## Features on the roadmap

Phase 16 brings full **App Store distribution** with notarisation and sandboxing hardening. (AirPlay routing shipped in Phase 15; Google Cast is excluded — no maintained macOS Cast SDK exists.)

See [`phases/`](phases/README.md) for the full roadmap.

---

## Naming

| Property | Value |
|----------|-------|
| Display name | Bòcan |
| Binary / package name | `bocan` |
| Bundle ID | `io.cloudcauldron.bocan` |
| Log subsystem | `io.cloudcauldron.bocan` |
| Minimum macOS | 26.0 (Tahoe) |

## Requirements

- macOS 26.0+
- Xcode 26+
- Homebrew (for FFmpeg, Chromaprint, TagLib, swiftlint, swiftformat, xcodegen, xcbeautify)

## Quick start

```bash
git clone https://github.com/bocan/bocan-music.git
cd bocan-music
make bootstrap     # brew bundle + bundle fpcalc dylibs + install git hooks
make generate      # xcodegen → Bocan.xcodeproj
make open          # opens in Xcode
```

`make bootstrap` installs all Homebrew dependencies (including `chromaprint` and `ffmpeg`) and then runs `Scripts/build-fpcalc.sh`, which copies `fpcalc` and its FFmpeg dylibs into `Resources/` with paths rewritten for the sandbox. You must run this before building — see [DEVELOPMENT.md](DEVELOPMENT.md) for details.

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
| `AudioEngine` | AVFoundation + FFmpeg decoder graph, ring buffer, DSP chain, playback actor |
| `Persistence` | GRDB schema + migrations, repositories, reactive `ValueObservation` |
| `Metadata` | TagLib read/write, cover-art extraction, LRC lyric parser |
| `Library` | Folder scanner, FSEvents watcher, conflict resolver, cover-art cache |
| `Playback` | Queue, history, shuffle strategies, gapless + crossfade scheduler, MPNowPlaying, sleep timer |
| `UI` | SwiftUI views, view models, mini player, settings, theming, snapshot tests |

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for detailed setup, the build system, FFmpeg and fpcalc notes, and contribution guidelines.

## Licence

See [LICENSE](LICENSE).
