# Bòcan Music

[![CI](https://github.com/bocan/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/ci.yml)
[![CodeQL](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![Xcode 26](https://img.shields.io/badge/Xcode-26-1575F9)

**The music player macOS deserves.** No Electron. No Catalyst. No subscription. No cloud. Just your music, played beautifully.

![Bòcan — Songs view](website/static/screenshots/Screenshot%202026-05-07%20at%2020.35.08.png)

---

## Why Bòcan?

Most Mac music players are either abandoned, Electron-wrapped, or stripped-down streaming clients that barely tolerate local files. Bòcan is the answer to all three — a **native Swift 6 app** built entirely around owning and enjoying your own library, the way iTunes used to before it became a content storefront.

### 🔊 It sounds better

- **True gapless playback** with nanosecond `AVAudioTime` anchoring — classical transitions, live albums, and DJ mixes play as the artist intended, with zero silence and zero clicks.
- **10-band graphic EQ**, bass boost, stereo expander, binaural crossfeed, and a **peak limiter** — a full DSP chain between your files and your ears.
- **ReplayGain** applied at playback time; analyses missing tags in the background using EBU R128 loudness.
- **Configurable crossfade** (0–12 s), **playback speed** (0.5×–2.0×) with pitch correction, and a **sleep timer** that fades gracefully rather than cutting mid-note.

### 📻 It plays everything

- Everything AVFoundation handles natively: **FLAC, ALAC, AAC, MP3, WAV, AIFF, CAF, M4A**.
- The awkward ones too, via an integrated FFmpeg bridge: **Ogg Vorbis, Opus, APE (Monkey's Audio), WavPack, DSD** — no plug-ins, no extra installs.

### 📚 It respects your library

- **Folder-based, non-destructive** — point it at your music directory and it indexes without touching a single file.
- **Live FSEvents watcher** picks up new or changed files automatically; **mtime + fingerprint deduplication** keeps your library clean.
- **AcoustID fingerprinting** against MusicBrainz — identify any track, preview every proposed tag change side-by-side with what you have now, tick the fields you want to update, and apply.
- **In-app tag editor** with multi-track batch editing, embedded cover-art drag-and-drop, and undo.

### 🎨 It's a pleasure to use

- **Three-pane browser** — Albums grid, Tracks list, Artists view, and Recently Added.
- **Smart Playlists** built from a rule editor, compiled to live SQL and updated automatically as your library changes.
- **Import / export** M3U, PLS, and XSPF playlists, with fuzzy track matching on import.
- **Real-time visualisers** — spectrum bars, oscilloscope, and a Metal GPU fluid shader — dockable or full-screen with `⌘⇧F`.
- **Mini Player** in three layouts (Strip, Compact, Square) with always-on-top mode.
- **Last.fm and ListenBrainz** scrobbling, offline-resilient with Keychain auth and a dead-letter queue.
- **AirPlay** routing via the system picker; a live route chip shows the current output device.

### ♿ It's accessible

Bòcan is designed to be fully navigable without a mouse or a screen:

- **VoiceOver-first track list** — each row announces *"Title, Artist, Album, Duration"* as a single spoken sentence rather than reading every column individually.
- **Live now-playing announcements** — when the track changes, VoiceOver speaks the new track name automatically, without you having to navigate to the transport bar.
- **Full keyboard navigation** with logical focus sections and no focus traps.
- **Dynamic Type** throughout — every label, badge, and table cell scales with your macOS text size setting.
- Album cells, artist rows, and genre chips are grouped with `.combine` so VoiceOver reads them as single logical elements.
- Transport controls carry state via `accessibilityValue` (e.g. *"Shuffle, on, button"*) so you always know what you're toggling.
- EQ band sliders report their gain in the format *"80 Hz, +3.0 dB"* rather than a raw number.

### 🏗️ It's engineered properly

- **Swift 6 strict concurrency** — `@MainActor` isolation, `Sendable` everywhere it matters, zero data races by design.
- **Seven clean SPM modules** with no upward imports and their own test suites.
- **80% line-coverage gate** in CI; the build fails if coverage drops.
- **GRDB 7** with typed repositories, FTS5 full-text search, and `ValueObservation`-based reactive streams.
- **XcodeGen** project generation — no hand-edited `.pbxproj` files in the repo.
- **CodeQL, SwiftLint, SwiftFormat, and Dependabot** on every pull request.

---

## On the name

**Bòcan** Naming things is hard. I was up from midnight to almost 3 am trying to figure out a name that wasn’t already taken for another app. In the end, I couldn’t find one that was free, so I went with the name I’ve used on the internet since the internet existed.

Bocán (Old Irish) means a young male deer, the root of which is cognate with the Welsh "boc" and the Breton "bok", both meaning "buck".

Bòcan (Scottish Gaelic, roughly *BAW-khan*) is a hobgoblin or a household spirit.

Bòcan curates your music library while you sleep. The short version is that computers don't like `ò`, so the binary, bundle, and repository all use `bocan`.

---

## What Bòcan can do right now

### Formats

- Plays every format AVFoundation knows about out of the box: **FLAC, ALAC, AAC, MP3, WAV, AIFF, CAF, M4A**.
- Also plays **Ogg Vorbis, Opus, APE (Monkey's Audio), WavPack, DSD, MP2/MP1, AC-3, DTS, WMA, Wave64, RF64, Matroska/MKV/WebM, and AU/SND** via a fully-integrated FFmpeg bridge — the formats every other Mac player makes you install a plug-in for.
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

- A tool to manage and organise files in the library.
- More visualisations.
- Remote control apps for iPhone and Android. To control the app on the mac - not to play remotely.
- Observability improvement.  Maybe a log _console_ in Tools.
- Very interested in improving accessiblity.
- Ideas very very welcome!

---

## Naming

| Property | Value |
|----------|-------|
| Display name | Bòcan |
| Binary / package name | `bocan` |
| Bundle ID | `io.cloudcauldron.bocan` |
| Log subsystem | `io.cloudcauldron.bocan` |
| Minimum macOS | 26.0 (Tahoe) |

## Install

**Download the DMG** from [bocan.app/download](https://bocan.app/download) or the [GitHub Releases](https://github.com/bocan/bocan-music/releases) page. Open it, drag Bòcan to Applications, done.

**Homebrew** — add the tap once, then install:

```bash
brew tap bocan/bocan
brew install bocan
```

Sparkle keeps the app current automatically. `brew upgrade --greedy bocan` does the same from the terminal if you prefer.

---

## Requirements (for building from source)

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

## And Last but Not Least

Much love to the giants whose shoulders I stand on:

- [Christopher Snowhill](https://kode54.net/), maintainer of of the excellent [Cog](https://cog.losno.co/).  The patron saint of native macOS music players and Cog is the direct spiritual ancestor of what I've built here.
- [Fabrice Bellard](https://bellard.org/), creator of [FFmpeg](https://ffmpeg.org/), and QEMU, and TinyCC, and a dozen other earth-shaking projects. The reason Bòcan can play Ogg, Opus, APE, WavPack, and DSD without making users install plugins.
- [Christopher "Monty" Montgomery](https://people.xiph.org/~xiphmont/) and the [Xiph.Org Foundation](https://xiph.org/) — Vorbis, FLAC, Opus, Speex. The entire free codec stack on which lossless audio on the open web is built.
- [Peter Pawlowski](https://www.foobar2000.org/), maintainer of [foobar2000](https://www.foobar2000.org/) — solo since 2002. Even though no foobar code touches Bòcan, foobar's design DNA (modular DSP, smart playlists, gapless, format breadth) is the spiritual blueprint of every audiophile-flavour music player that has followed.
- [Lukáš Lalinský](https://oxygene.sk/), creator of [Chromaprint](https://acoustid.org/chromaprint) and [AcoustID](https://acoustid.org/) — the entire fingerprinting and auto-tagging pipeline in Bòcan exists because of his work. Also a long-time TagLib contributor. A one-person open-source music-metadata hero.
- [Scott Wheeler](https://github.com/wheels/) and the [TagLib](https://taglib.org/) contributors — without TagLib, I'd be reimplementing ID3v2.4 + Vorbis comments + APE tags + MP4 atoms by hand.
- [Robert Kaye](https://blog.metabrainz.org/author/robert/) and the [MetaBrainz Foundation](https://metabrainz.org/) — [MusicBrainz](https://musicbrainz.org/), [ListenBrainz](https://listenbrainz.org/), [Cover Art Archive](https://coverartarchive.org/). Bòcan's auto-tagging, lookup, and open scrobbling all sit on this stack.
- [Gwendal Roué](https://github.com/groue), maintainer of [GRDB.swift](https://github.com/groue/GRDB.swift) — quietly one of the best-maintained Swift libraries in existence, solo for over a decade. My entire persistence layer is built on it.
- [Justin Frankel](https://www.cockos.com/~justin/), co-creator of [Winamp](https://en.wikipedia.org/wiki/Winamp) (back in his Nullsoft days), later [REAPER](https://www.reaper.fm/), NSIS, gnutella, and most of [Cockos](https://www.cockos.com/). Winamp basically invented the modern desktop music player. Anyone building one stands on this work whether they realise it or not.
- [Jean-Marc Valin](https://jmvalin.dreamwidth.org/), primary author of [Opus](https://opus-codec.org/) (and Speex before that) — one of the great open codec achievements of the last twenty years.
- [Yonas Kolb](https://github.com/yonaskolb), creator of [XcodeGen](https://github.com/yonaskolb/XcodeGen) — saved me (and everyone else) from hand-editing `.pbxproj` and weeping in merge conflicts.
- [Nick Lockwood](https://github.com/nicklockwood), author of [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) — keeps my codebase from looking like it was written by seven different people on seven different keyboards.
- [JP Simard](https://github.com/jpsim), creator of [SwiftLint](https://github.com/realm/SwiftLint) — the linter that enforces my `.swiftlint.yml` on every commit.

