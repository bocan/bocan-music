# Bòcan — Phased Build Plan

A vibe-coded, test-driven, native macOS music player built with the latest Swift, SwiftUI, and AVFoundation. This document is structured so that each phase is small enough to fit comfortably in a single Claude Code session (or two) without overwhelming the context window. Phases are **strictly ordered by dependency** — later phases assume earlier phases are complete and tested.

## On the Name

**Bòcan** (Scottish Gaelic, pronounced roughly _BAW-khan_) is a hobgoblin — a solitary domestic spirit in Scottish Highland folklore, bound to a particular household or family, sometimes helpful and sometimes mischievous. The word carries three layers of Celtic etymology stacked on top of one another:

1. **Literal:** from Proto-Celtic `*bukko-s` ("goat"), giving Old Irish `bocán` — "little buck," a young male deer or he-goat.
2. **Folkloric:** in Scottish Gaelic, `bòcan` evolved to mean "hobgoblin, spectre, apparition" — the supernatural creatures in question being associated with goat-like features.
3. **Mythological:** the `Bocánaigh` of early Irish and Scottish lore were aerial battle-spirits, glossed by monastic scribes as "demons of the air."
The player is therefore named after the hobgoblin that curates your music library, the young buck that runs swift and wild, and the spirit on the air that carries songs from elsewhere. Pick whichever layer you prefer on a given day.

## Naming Convention

Because `ò` isn't a friendly character for computers:

| Context | Form |
|---|---|
| App display name, window title, Dock, menu bar, README headings | **Bòcan** |
| Bundle ID, package names, binary, repo, file names, Xcode scheme, anywhere a computer reads it | `bocan` |
| In prose inside this document | `Bòcan` (the display form) |

So: the built app is called **Bòcan**, but the executable binary is `bocan`, the Swift package is `bocan`, the bundle ID is `io.cloudcauldron.bocan`, and the repo is `github.com/bocan/bocan-player` (or similar — `github.com/bocan/bocan` is reserved by GitHub as your profile README repo).

---

## Reality Checks Before You Start

A few things were pruned or reshaped from the original brief based on the current state of the world (April 2026):

| Item | Status | Decision |
|---|---|---|
| **Chromecast Audio** (dongle) | Discontinued by Google in 2019 | Reframe as "Cast to Google Cast devices" — works for regular Chromecast/Google TV/Nest Audio targets. Existing Chromecast Audio dongles still receive casts. |
| **MQA support** | MQA Ltd entered administration in 2023, acquired by Lenbrook. Tidal dropped it. Licensing future is unclear. | **Recommend dropping from scope.** Decoding requires a licensed SDK that may not be obtainable. |
| **DSD support** | Not native to AVFoundation | Requires FFmpeg bridge or custom decoder. Treated as a Phase 1 architectural concern, not a bolt-on. |
| **OGG/Vorbis/Opus** | Not native to AVFoundation | Same — needs FFmpeg bridge from day one. |
| **Last.fm** | API still alive but lower-priority for the company | Should still work. Have a fallback plan (ListenBrainz is open and a clean swap-in). |

---

## Cross-Cutting Standards (applies to every phase)

These are the non-functional requirements baked into the workflow. **Read this once, then assume they apply everywhere.**

### Language & Tooling
- **Swift 6+** with strict concurrency enabled
- **SwiftUI** primary, with `NSViewRepresentable` drop-downs to AppKit only when SwiftUI genuinely can't deliver
- **macOS 14+ minimum target** (gives you SwiftData, modern Observation, Swift Testing macros)
- **Xcode 16+** for Swift Testing macro support
- **SPM** (Swift Package Manager) for all dependencies — no CocoaPods, no Carthage
### Use Context7 For
Add `use context7` to every Claude Code prompt that touches:
- SwiftUI APIs (still evolving fast)
- Swift Concurrency / Swift 6 actor model
- AVFoundation / AVAudioEngine
- SwiftData (if you choose it over GRDB)
- Swift Testing macros
For Apple's own framework documentation, also keep [developer.apple.com](https://developer.apple.com/documentation/) open in a browser tab — Context7's coverage of Apple frameworks is decent but not exhaustive.

### Testing Standard
- **Swift Testing** (the new macro-based framework) for unit and integration tests
- **XCUITest** for UI smoke tests
- **80% line coverage minimum** — enforced in CI, build fails if it drops below
- Every public function gets a test. Every bug fix gets a regression test. No exceptions.
- Use `swift-snapshot-testing` for SwiftUI view snapshot tests
### Logging & Observability
- **OSLog** as the underlying logger (integrates with Console.app, Instruments, sysdiagnose)
- Wrap OSLog in a thin `Logger` facade so you can swap implementations
- Use **structured logging** — log key/value pairs, never string-interpolated blobs
- Subsystem: `io.cloudcauldron.bocan` (or your reverse-DNS), categories per module (`audio`, `library`, `ui`, `network`, etc.)
- **MetricKit** for system-level metrics (energy, hangs, disk I/O) — free observability you'd be daft not to use
- Optional: **swift-distributed-tracing** + OpenTelemetry exporter for power users — gated behind a debug menu, off by default
- Every async operation logs entry, exit, and duration at `.debug` level
- Every error logs at `.error` with full context
### Build & Release
- **Makefile** at repo root for all common dev tasks (see Phase 0)
- **GitHub Actions** for CI (lint + test + coverage on PR) and release (build, sign, notarize, attach to GitHub Release)
- **SwiftLint** + **SwiftFormat** with config files committed
- **Conventional Commits** + automated changelog generation
---

# Phase 0 — Foundations

**Goal:** A repo that builds nothing useful but does so beautifully. Everything from here forward is content; this phase is the chassis.

**Why first:** If you skip this and try to retrofit, you'll hate yourself. Tests, logging, CI, and Makefile are non-negotiable scaffolding.

## Steps

1. **Initialise the Xcode project**
   - macOS App, SwiftUI lifecycle, Swift Testing
   - Bundle ID: `io.cloudcauldron.bocan` (or your preferred reverse DNS)
   - Enable Swift 6 strict concurrency in build settings
   - Hardened Runtime enabled
   - Sandbox enabled (you'll need entitlements for file access — `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`)
2. **Repo structure**
   ```
   /
   ├── App/                    # @main entry point, App definition
   ├── Modules/                # Feature modules (one Swift Package each)
   │   ├── AudioEngine/
   │   ├── Library/
   │   ├── Metadata/
   │   ├── Persistence/
   │   ├── UI/
   │   └── Observability/
   ├── Tests/                  # Cross-module integration tests
   ├── UITests/
   ├── Resources/              # Assets, Info.plist, entitlements
   ├── Scripts/                # Build/release helpers
   ├── .github/workflows/      # CI/CD
   ├── Makefile
   ├── .swiftlint.yml
   ├── .swiftformat
   ├── README.md
   └── BUILD_PLAN.md           # this document
   ```
   Each module under `Modules/` is its own Swift Package. This forces clean boundaries and makes testing in isolation trivial.
3. **Makefile**
   ```makefile
   .PHONY: bootstrap build test test-coverage lint format run clean release-local

   APP_NAME := Bocan
   SCHEME := $(APP_NAME)

   bootstrap:           ## Install dev dependencies
   	@brew bundle --file=./Brewfile

   build:               ## Build debug
   	@xcodebuild build -scheme $(SCHEME) -configuration Debug

   test:                ## Run all tests
   	@xcodebuild test -scheme $(SCHEME) -destination 'platform=macOS'

   test-coverage:       ## Run tests with coverage report
   	@xcodebuild test -scheme $(SCHEME) -destination 'platform=macOS' \
   		-enableCodeCoverage YES -resultBundlePath ./build/TestResults.xcresult
   	@./Scripts/coverage-report.sh

   lint:                ## Run linters
   	@swiftlint
   	@swiftformat --lint .

   format:              ## Auto-format code
   	@swiftformat .

   run:                 ## Run debug build
   	@xcodebuild build -scheme $(SCHEME) -configuration Debug
   	@open ./build/Debug/$(APP_NAME).app

   clean:               ## Clean build artefacts
   	@xcodebuild clean
   	@rm -rf ./build

   release-local:       ## Build a signed local release
   	@./Scripts/build-release.sh

   help:                ## Show this help
   	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
   ```

4. **Brewfile** for tooling
   ```ruby
   brew "swiftlint"
   brew "swiftformat"
   brew "xcbeautify"
   brew "ffmpeg"           # needed later for non-native formats
   brew "create-dmg"       # for releases
   ```

5. **GitHub Actions — `.github/workflows/ci.yml`**
   - Trigger on PR and push to main
   - Run on `macos-15` (or latest) runner
   - Steps: checkout → install brew deps → swiftlint → swiftformat lint → build → test with coverage → upload coverage artefact → fail if coverage < 80%
6. **GitHub Actions — `.github/workflows/release.yml`**
   - Trigger on tag matching `v*.*.*`
   - Build release configuration
   - Sign with Developer ID (cert in repo secrets)
   - Notarize via `notarytool`
   - Build DMG with `create-dmg`
   - Attach DMG to GitHub Release
   - Generate changelog from conventional commits
7. **Observability module skeleton** (`Modules/Observability/`)
   - `AppLogger` actor wrapping OSLog
   - Categories: `audio`, `library`, `ui`, `network`, `persistence`, `metadata`
   - Log levels mapped to OSLog levels: `.trace → .debug`, etc.
   - `Telemetry` namespace for metrics (counters, timers) backed by MetricKit
   - Test that loggers emit expected output (use `OSLogStore` to read back)
## Tests for Phase 0
- Logger emits at correct levels and categories
- Logger redacts known sensitive keys (e.g. `apiKey`, `token`)
- Makefile targets exist and are runnable (lightweight smoke test in CI)
## Acceptance Criteria
- [ ] `make bootstrap && make test` works from clean checkout
- [ ] CI passes on a no-op PR
- [ ] Coverage report generates and is readable
- [ ] OSLog entries visible in Console.app under your subsystem
- [ ] Empty app launches and shows a window saying "Hello"
---

# Phase 1 — Audio Engine Architecture & Single-File Playback

**Goal:** Play any supported audio file. Just one file. Pause, resume, seek, stop. Nothing else.

**Why now:** The decoder strategy decides everything downstream. Get this wrong and every later phase pays the tax.

## The Decoder Strategy

You need to handle two classes of format:

1. **AVFoundation-native:** MP3, AAC, ALAC, AIFF, WAV, FLAC (since macOS 10.13)
2. **Non-native:** OGG/Vorbis, Opus, DSD (DSF/DFF), APE, WavPack
For (1), use `AVAudioFile` → `AVAudioPlayerNode` directly.
For (2), bridge via FFmpeg (libavcodec/libavformat) → produce PCM buffers → feed into `AVAudioPlayerNode`.

**Architecture:**

```
                 ┌─────────────────┐
                 │  AudioEngine    │   (your facade)
                 └────────┬────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
   ┌──────────────┐                ┌──────────────┐
   │   Decoder    │  (protocol)    │  AVAudio-    │
   │   protocol   │                │  Engine      │
   └──┬───────┬───┘                └──────────────┘
      │       │
      ▼       ▼
   ┌─────┐ ┌─────────────┐
   │ AV  │ │ FFmpeg      │
   │ Dec │ │ Decoder     │
   └─────┘ └─────────────┘
```

A `Decoder` protocol returns PCM buffers. The engine doesn't care where they came from. This lets you add format support later without touching playback code.

## Steps

1. **Create `AudioEngine` module** (Swift Package)
2. **Define `Decoder` protocol**
   - `init(url: URL) throws`
   - `read(into buffer: AVAudioPCMBuffer) async throws -> Int`
   - `seek(to time: TimeInterval) async throws`
   - `var format: AVAudioFormat { get }`
   - `var duration: TimeInterval { get }`
3. **Implement `AVFoundationDecoder`** — wraps `AVAudioFile`
4. **Vendor FFmpeg via SPM** — use the `SwiftFFmpeg` package or build your own thin binding. Static-link to keep distribution simple.
5. **Implement `FFmpegDecoder`** — use libavcodec to decode to PCM, convert sample format to match output, return buffers
6. **Implement `DecoderFactory`** — sniff the file (magic bytes, not just extension) and return the right decoder
7. **Build `AudioEngine`** — owns an `AVAudioEngine`, an `AVAudioPlayerNode`, and a current `Decoder`. Pull buffers in a background task, schedule them on the player node.
8. **Transport API** — `play()`, `pause()`, `stop()`, `seek(to:)`, `currentTime`, `duration`, `isPlaying`
9. **Output device selection** — query `AVAudioEngine.outputNode` and let the user pick output devices later (just expose the API now)
10. **Logging at every stage** — file opened, format detected, decoder selected, buffers scheduled, errors
## Context7 Lookups
- `use context7 AVAudioEngine`
- `use context7 AVAudioPlayerNode scheduling`
- `use context7 Swift 6 strict concurrency AVFoundation`
## Tests
- Each decoder: opens a fixture file, reads N bytes, returns expected PCM
- Format detection: feeds known magic bytes, gets correct decoder
- Engine: plays a 1-second sine wave fixture and the output buffer matches expected
- Engine: seek to a known position, verify position
- Error paths: corrupt file, unsupported format, missing file
- **Property-based test:** play → pause → resume → position is consistent
## Acceptance Criteria
- [ ] Plays MP3, AAC, ALAC, FLAC, WAV via AVFoundation decoder
- [ ] Plays OGG, Opus, DSF via FFmpeg decoder
- [ ] All transport controls work
- [ ] Logs are clean and informative
- [ ] Coverage > 80% in this module
---

# Phase 2 — Persistence Layer (SQLite)

**Goal:** A local SQLite database with a comprehensive schema for music metadata. No UI. No scanning yet. Just the data layer.

**Why now:** Library, playlists, smart playlists, scrobbles — all of it sits on top of this. Get the schema right.

## Library Choice: GRDB.swift over SwiftData

You said SQLite, and I'd push you towards [GRDB.swift](https://github.com/groue/GRDB.swift) over SwiftData for these reasons:
- Mature, battle-tested, no Apple-specific weirdness
- Full SQL when you need it (and you will, for smart playlists)
- Excellent concurrency model (`DatabaseQueue` / `DatabasePool`)
- Type-safe migrations
- Reactive observation via Combine/AsyncSequence
SwiftData is fine for simpler apps but the smart-playlist criteria builder is going to need real SQL, and SwiftData's predicate system is restrictive.

## Schema (initial draft — expand as needed)

```sql
-- Tracks
CREATE TABLE tracks (
    id INTEGER PRIMARY KEY,
    file_url TEXT NOT NULL UNIQUE,
    file_bookmark BLOB,                 -- security-scoped bookmark for sandboxed access
    file_size INTEGER NOT NULL,
    file_mtime INTEGER NOT NULL,
    file_format TEXT NOT NULL,          -- 'flac', 'mp3', etc
    -- audio properties
    duration REAL NOT NULL,
    sample_rate INTEGER,
    bit_depth INTEGER,
    bitrate INTEGER,
    channel_count INTEGER,
    is_lossless BOOLEAN,
    -- core tags
    title TEXT,
    artist_id INTEGER REFERENCES artists(id),
    album_artist_id INTEGER REFERENCES artists(id),
    album_id INTEGER REFERENCES albums(id),
    track_number INTEGER,
    disc_number INTEGER,
    year INTEGER,
    genre TEXT,
    composer TEXT,
    -- extended
    bpm REAL,
    key TEXT,
    isrc TEXT,
    musicbrainz_track_id TEXT,
    musicbrainz_recording_id TEXT,
    replaygain_track_gain REAL,
    replaygain_track_peak REAL,
    replaygain_album_gain REAL,
    replaygain_album_peak REAL,
    -- player state
    play_count INTEGER DEFAULT 0,
    skip_count INTEGER DEFAULT 0,
    last_played_at INTEGER,
    rating INTEGER,                     -- 0-5 or 0-100
    loved BOOLEAN DEFAULT 0,
    excluded_from_shuffle BOOLEAN DEFAULT 0,
    -- bookkeeping
    added_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE artists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    sort_name TEXT,
    musicbrainz_artist_id TEXT,
    UNIQUE(name)
);

CREATE TABLE albums (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    album_artist_id INTEGER REFERENCES artists(id),
    year INTEGER,
    musicbrainz_release_id TEXT,
    cover_art_path TEXT,                -- path in app cache
    cover_art_hash TEXT,                -- for deduplication
    UNIQUE(title, album_artist_id)
);

CREATE TABLE playlists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    is_smart BOOLEAN DEFAULT 0,
    smart_criteria TEXT,                -- JSON for smart playlist rules
    sort_order INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE playlist_tracks (
    playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
    track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, position)
);

CREATE TABLE lyrics (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    lyrics_text TEXT,
    is_synced BOOLEAN DEFAULT 0,        -- LRC format
    source TEXT                         -- 'embedded', 'lrc-file', 'fetched'
);

CREATE TABLE scrobble_queue (
    id INTEGER PRIMARY KEY,
    track_id INTEGER REFERENCES tracks(id),
    played_at INTEGER NOT NULL,
    duration_played REAL,
    submitted BOOLEAN DEFAULT 0,
    submission_attempts INTEGER DEFAULT 0
);

-- Full-text search
CREATE VIRTUAL TABLE tracks_fts USING fts5(
    title, content=tracks, content_rowid=id,
    tokenize='unicode61 remove_diacritics 2'
);
-- And similar FTS tables for artists, albums

-- Triggers to keep FTS in sync
```

Add indexes liberally — anything you'll filter or sort by.

## Steps

1. **Create `Persistence` module**
2. **Add GRDB.swift via SPM**
3. **Define migrations** — every schema change is a numbered migration, applied in order. First migration is the schema above.
4. **Define record types** — Codable structs that map to tables
5. **Define repositories** — `TrackRepository`, `AlbumRepository`, etc. All DB access goes through these. Tests can mock them.
6. **Database location** — `~/Library/Application Support/Bocan/library.sqlite`
7. **Backup hook** — write the DB to iCloud Drive periodically (opt-in setting later)
8. **Reactive observation** — wrap GRDB's `ValueObservation` in `AsyncSequence` for SwiftUI integration
## Context7 Lookups
- `use context7 GRDB.swift migrations`
- `use context7 GRDB.swift ValueObservation`
- `use context7 Swift 6 sendable database`
## Tests
- Each migration applies cleanly to the previous schema
- Each repository CRUD path
- FTS search returns expected results for unicode/diacritic edge cases
- Concurrent reads don't deadlock
- Cascade deletes work as expected
- Insert performance: 10,000 tracks in < 5 seconds (you'll thank yourself later)
## Acceptance Criteria
- [ ] Empty database created and migrated on first launch
- [ ] All repositories testable in isolation with in-memory DB
- [ ] Coverage > 80%
---

# Phase 3 — Library Scanning & Metadata Extraction

**Goal:** Point at a folder, walk it, extract every scrap of metadata, persist to the database. Watch for changes.

## Steps

1. **Tag library choice:** wrap **TagLib** (C++) via a Swift bridging header. It handles ID3v1, ID3v2, MP4, FLAC/Vorbis comments, APE tags, WMA, the lot. Alternatives like SwiftTagger only cover ID3 and MP4 — not enough.
2. **Scanner module** with progress reporting via `AsyncStream<ScanProgress>`
3. **Background scanning** — Swift concurrency, configurable parallelism
4. **Security-scoped bookmarks** — store these so you can re-access files after restart in the sandbox
5. **FSEvents watching** — `DispatchSource.makeFileSystemObjectSource` or `FSEventStreamCreate` to detect changes
6. **Embedded cover art extraction** — pull from tags, hash, dedupe, store in app cache
7. **Replay Gain extraction** — read from tags (Phase 9 can compute it for files that don't have it)
8. **Lyrics extraction** — pull USLT (unsynced) and SYLT (synced) frames, also check for sidecar `.lrc` files
9. **Scan strategy:**
   - **Quick scan:** stat-only, find new/removed/modified files based on mtime
   - **Full scan:** re-read all metadata from disk
10. **Conflict resolution** — if user edits a tag in your app vs the file changes on disk, who wins? (Decision: user edits win, marked as "modified"; on next disk change you prompt.)
## Context7 Lookups
- `use context7 Swift FSEventStreamCreate`
- `use context7 Swift security-scoped bookmark`
- `use context7 Swift concurrency TaskGroup`
## Tests
- Scan a fixture folder of ~50 files across all supported formats — verify all metadata extracted correctly
- Quick scan correctly identifies added/removed/modified files
- Cover art deduplication: same image embedded in 12 tracks → stored once
- Edge cases: missing tags, corrupted tags, non-ASCII filenames, very long paths, files with no extension, broken symlinks, files that disappear mid-scan
- Performance: scan 10,000-file fixture library in reasonable time
- FSEvents trigger correct rescan actions
## Acceptance Criteria
- [ ] Pick a folder, scan completes, library populated
- [ ] Adding a file to the watched folder shows up without manual rescan
- [ ] Removing a file removes it from library
- [ ] Cover art extracted, deduped, cached
- [ ] Lyrics extracted (where present)
---

# Phase 4 — Library UI

**Goal:** Browse the library you just built. Three-pane layout: source list (sidebar) | content area | now-playing strip.

## Layout

- **Sidebar:** Library, Artists, Albums, Genres, Composers, Recently Added, Recently Played, Most Played, [Playlists section]
- **Content area:** changes based on sidebar selection
  - Albums view: grid of cover art, click → tracks
  - Artists view: list, click → albums
  - Tracks view: data table with sortable columns
- **Now playing strip:** bottom bar with art thumbnail, title/artist, transport, scrubber, volume
## Steps

1. **`UI` module** with feature subdirectories
2. **Three-column `NavigationSplitView`** with collapsible sidebar
3. **Album grid** — `LazyVGrid` with adaptive columns, async cover loading with placeholder
4. **Track table** — `Table` view (SwiftUI native) with sortable columns: title, artist, album, duration, year, plays, rating
5. **Search** — global search bar driving FTS query
6. **Multi-select** for tracks (you specifically asked for this) — `Set<Track.ID>` selection state
7. **Context menus** — right-click for play, queue, add to playlist, edit metadata, reveal in Finder, etc.
8. **Keyboard navigation** — arrow keys, space to play/pause, return to play selected
9. **Drag and drop** — into playlists, out to Finder
10. **Light/dark mode** — automatic from system, both must look intentional. Test both with snapshot tests.
## Context7 Lookups
- `use context7 SwiftUI NavigationSplitView`
- `use context7 SwiftUI Table sortable`
- `use context7 SwiftUI LazyVGrid performance`
- `use context7 SwiftUI drag drop`
## Tests
- Snapshot tests for each major view in light and dark mode
- ViewModel tests: selection, sorting, filtering all behave correctly
- Search returns expected results
- Multi-select works with shift-click and cmd-click
- Keyboard shortcuts trigger correct actions
## Acceptance Criteria
- [ ] Navigate library by sidebar
- [ ] Search works fast even on 10k+ tracks
- [ ] Multi-select feels native
- [ ] Looks good in light AND dark
- [ ] Right-click context menus everywhere they belong
---

# Phase 5 — Playback Queue & Gapless Playback

**Goal:** A real player. Queue management, next/previous, gapless transitions between tracks.

**Why now:** You have decoders (Phase 1) and a library (Phases 2-4). Now string them together properly.

## The Gapless Trick

Gapless playback in AVAudioEngine is achieved by **scheduling the next file's first buffer to play immediately after the current file's last buffer**, with no time gap. The trick is:

1. Pre-decode the next track while current is playing (start when current is ~5 seconds from the end)
2. Use `AVAudioPlayerNode.scheduleBuffer(_:at:)` with an explicit `AVAudioTime` that lines up with current track's end
3. Both tracks must share the same `AVAudioFormat` — if they don't, you need a format converter node in the chain (an `AVAudioMixerNode` handles this)
4. Start a new `AVAudioPlayerNode` for the new track and crossfade if needed; or seamlessly hand off
## Steps

1. **`PlaybackQueue` actor** — ordered list of tracks, current index, history, repeat/shuffle state
2. **Queue manipulation API** — append, prepend, insert at, remove, move, clear
3. **Next/previous track logic** with proper history
4. **Repeat modes** — off, all, one
5. **Shuffle** with **exclusion** — when shuffle is on, skip tracks where `excluded_from_shuffle = 1`
6. **Smart shuffle** — weighted by play count, rating, recency (give it a personality, not just `Array.shuffled()`)
7. **Pre-decode next track** when current track has < 5s remaining
8. **Gapless scheduling** between tracks of compatible formats
9. **Track-changed events** as `AsyncStream<Track>` for UI to subscribe to
10. **Now Playing Info Center** — populate `MPNowPlayingInfoCenter` so media keys, Touch Bar, Control Centre, and AirPods controls all work
11. **Remote command handling** — `MPRemoteCommandCenter` for play/pause/next/prev/seek/scrub from external sources
## Context7 Lookups
- `use context7 AVAudioPlayerNode scheduleBuffer at time`
- `use context7 AVAudioTime sample-accurate`
- `use context7 MPNowPlayingInfoCenter macOS`
- `use context7 MPRemoteCommandCenter`
## Tests
- Queue operations are correct (append, remove, move) with property-based tests
- Repeat modes loop correctly
- Shuffle excludes excluded tracks
- Shuffle is deterministic when seeded (for testing)
- Gapless test: play two known sine-wave fixtures, verify no gap or discontinuity in output samples
- Pre-decode triggered at correct point
- Now Playing Info populated correctly
## Acceptance Criteria
- [ ] Queue and play through an entire album with no gaps between tracks
- [ ] Media keys work
- [ ] AirPods next/previous work
- [ ] Shuffle respects exclusion
- [ ] Test gapless with a known live album (e.g. _Dark Side of the Moon_)
---

# Phase 6 — Manual Playlists

**Goal:** Create, edit, reorder, delete playlists. Multi-select-to-create workflow.

## Steps

1. **Playlist CRUD repository methods**
2. **Sidebar section** for playlists with rename in place, delete with confirm
3. **Multi-select-to-playlist:**
   - Select tracks in any view → context menu → "New Playlist from Selection" or "Add to Playlist >"
   - Drag-drop multiple tracks onto a sidebar playlist
4. **Playlist view** — like tracks view, with reorder via drag
5. **Folders for playlists** (optional, nice to have)
6. **Playlist colour/icon** customisation (small touch, big personality)
## Tests
- Playlist CRUD round-trip
- Multi-select → playlist creates with all selected tracks in correct order
- Reorder persists
- Delete cascades correctly (delete playlist, tracks remain in library)
## Acceptance Criteria
- [ ] Select 20 tracks, create playlist in one motion
- [ ] Drag to reorder feels good
- [ ] Empty playlist looks intentional, not broken
---

# Phase 7 — Smart Playlists

**Goal:** Rule-based playlists that auto-update as the library changes.

## Steps

1. **Criteria model** — codable JSON structure:
   ```swift
   enum SmartCriterion {
       case field(Field, Comparator, Value)
       case group(LogicalOp, [SmartCriterion])
   }
   ```
2. **Criteria → SQL compiler** — transforms criteria into a parameterised SQL `WHERE` clause
3. **Criteria builder UI** — iTunes/Music.app-style rule editor
4. **Limit and sort options** — "Most played, limit 25", "Random 50, by added date"
5. **Live update** — observe DB changes, recompute playlist contents
6. **Common templates** — "Recently Added", "Top 25 Most Played", "Unrated", "Loved", "Genre: X" as starter presets
## Tests
- Each comparator (`is`, `is not`, `contains`, `matches regex`, `>`, `<`, `between`, `in last N days`) compiles correctly
- Nested groups (AND of ORs etc.) compile correctly
- Live update fires when matching tracks change
- SQL injection attempts in user input are safely parameterised
## Acceptance Criteria
- [ ] Create a smart playlist "5-star rock from the 70s, played < 5 times" and it works
- [ ] Edits to tracks update smart playlists immediately
---

# Phase 8 — Metadata Editor & Cover Art Fetching

**Goal:** Edit tags in-app. Fetch missing cover art from MusicBrainz/Cover Art Archive.

## Steps

1. **Tag editor sheet** — single-track and multi-track edit modes
2. **Multi-track edit:** show `<various>` for differing fields, only write fields the user actually changed
3. **Write back to file** via TagLib
4. **Update DB** to match
5. **Cover art fetcher:**
   - Query MusicBrainz API for release ID by artist + album
   - Fetch image from Cover Art Archive
   - User picks if multiple results
   - Embed in file (optional setting) AND store in app cache
6. **Manual cover art** — drag-drop image onto album, or paste from clipboard
7. **Batch operations:**
   - Fetch missing cover art for whole library
   - Find duplicate tracks (by acoustic fingerprint? out of scope; by tags + duration is fine)
## Context7 Lookups
- `use context7 SwiftUI sheet form`
- `use context7 URLSession async`
## Tests
- Edit single tag, save, re-read from disk, verify
- Multi-edit only modifies changed fields
- Cover art fetcher: mock MusicBrainz responses, verify correct flow
- Failed network gracefully degrades
- Rate limit MusicBrainz API (1 req/sec) is respected
## Acceptance Criteria
- [ ] Fix a typo in an artist name across 12 tracks in one go
- [ ] Auto-fetch cover art for an album that's missing it
- [ ] Edits round-trip through the file system
---

# Phase 9 — Multi-Band EQ & Audio Effects

**Goal:** 10-band parametric EQ, bass boost, virtualizer (crossfeed for headphones), stereo expansion. Presets. User presets.

## Steps

1. **Insert `AVAudioUnitEQ` node** in the engine chain after the player nodes
2. **10 bands** at standard ISO frequencies: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz
3. **Bass boost** — separate `AVAudioUnitEQ` band with shelf filter, or use a dedicated bass EQ
4. **Virtualizer / crossfeed** — for headphones, simulates speaker stereo. Either use `AVAudioUnitReverb` lightly, or implement a Bauer crossfeed (simple IIR filter — small custom AU)
5. **Stereo expansion** — mid/side processing via custom `AVAudioUnit` or matrix in a tap
6. **Compute Replay Gain** for tracks that don't have it (background task, optional)
7. **Apply Replay Gain** in the chain (just a gain stage)
8. **Preset management** — built-in presets (Rock, Jazz, Classical, Vocal Boost, etc.) plus user-saved
9. **A/B compare** — toggle EQ off temporarily to hear the difference
10. **Per-track / per-album / global** EQ assignment
## Context7 Lookups
- `use context7 AVAudioUnitEQ`
- `use context7 AVAudioUnit custom`
## Tests
- EQ band changes produce expected frequency response (process white noise, FFT, verify)
- Presets save and load
- Bypass mode is truly bypassed (output samples == input samples within FP epsilon)
- Replay Gain calculation matches reference values for known fixtures
## Acceptance Criteria
- [ ] Visible 10-band EQ with sliders that respond instantly
- [ ] Presets work
- [ ] Toggle on/off without glitches
- [ ] Replay Gain prevents loudness whiplash between tracks
---

# Phase 10 — Mini Player, Window Modes, Polish

**Goal:** Full mode (everything you've built) + a slick resizable mini player. Refined light/dark themes.

## Steps

1. **Mini player as a separate `Window`** in the SwiftUI `App` definition
2. **Mini player layout** — compact, just art + title + transport + scrubber. Resizable to a tiny strip or a square.
3. **Toggle between modes** with `⌘M` (or similar) and a menu bar item
4. **Always-on-top option** for mini player
5. **Refine themes** — go through every view, every state, both modes. Snapshot tests for everything.
6. **Custom colours** — let the user pick an accent, use it consistently
7. **Menu bar item** (optional) — quick play/pause + currently playing without bringing window forward
8. **Dock badge / icon** showing now-playing thumbnail (NSDockTile)
9. **Notification on track change** (optional, off by default)
## Context7 Lookups
- `use context7 SwiftUI multiple windows`
- `use context7 NSDockTile SwiftUI`
## Tests
- Window state preserved across launches (mini vs full, position, size)
- Snapshot tests for mini player at small/medium/large sizes
- All views render correctly in both modes
## Acceptance Criteria
- [ ] Mini player looks good at any reasonable size
- [ ] Switching modes is instant and remembers state
- [ ] Both themes look intentional everywhere
---

# Phase 11 — Lyrics

**Goal:** Display embedded and synced lyrics. Auto-scroll for synced.

## Steps

1. **Lyrics view** — scrollable, current line highlighted for synced
2. **LRC parser** — parse `[mm:ss.xx]` timestamps
3. **Auto-scroll** for synced lyrics, following playback position
4. **Manual edit** — paste lyrics, save (embedded back into file optionally)
5. **Optional fetcher** — note: most lyrics APIs have hostile terms; LRClib is community-driven and friendlier. Make it opt-in.
## Tests
- LRC parser handles all common timestamp formats
- Scroll position matches playback time within tolerance
- Edit round-trips through file
## Acceptance Criteria
- [ ] Synced lyrics scroll in time with the music
- [ ] Embedded lyrics show by default
- [ ] Can paste lyrics for tracks that have none
---

# Phase 12 — Visualizers

**Goal:** Draw pretty things in time with the music. At least 2-3 modes.

## Steps

1. **Audio tap** — install a tap on a node in the engine to read PCM frames in real time
2. **FFT** via `vDSP` (Accelerate framework) for frequency-domain visualizers
3. **Visualizer protocol** — render to a `MetalView` or `Canvas` given audio data
4. **Implementations:**
   - Spectrum analyser (bars)
   - Waveform / oscilloscope
   - Particles / fluid (more ambitious, Metal-based)
5. **Fullscreen mode** for visualizers
6. **Performance budget** — 60fps minimum, monitor with MetricKit
## Context7 Lookups
- `use context7 vDSP FFT Swift`
- `use context7 SwiftUI Canvas TimelineView`
- `use context7 AVAudioEngine installTap`
## Tests
- FFT produces expected frequency peaks for known sine inputs
- Tap doesn't drop samples or affect playback timing
- Visualizers don't leak memory over long sessions
## Acceptance Criteria
- [ ] At least 3 visualizer modes
- [ ] No frame drops during normal playback
- [ ] Doesn't murder battery on a laptop
---

# Phase 13 — Last.fm Scrobbling

**Goal:** Scrobble plays to Last.fm. Queue offline, retry on reconnect.

## Steps

1. **Auth flow** — Last.fm uses a token-based desktop auth. Open browser, user authorises, app polls for session key.
2. **Scrobble rules:** track must be > 30s long AND user has listened > 50% OR > 4 minutes
3. **Now Playing update** — sent when track starts (separate from scrobble)
4. **Offline queue** in the `scrobble_queue` table
5. **Retry with backoff** for failed submissions
6. **ListenBrainz adapter** — same interface, different backend. Future-proofing.
7. **Settings UI** for connect/disconnect, view recent scrobbles
## Tests
- Scrobble rules apply correctly to various play scenarios
- Offline scrobbles queued and submitted on reconnect
- Auth flow handles user denial gracefully
- API responses parsed correctly (mock the network)
## Acceptance Criteria
- [ ] Connect Last.fm account
- [ ] Plays show up on Last.fm profile
- [ ] Disconnect/reconnect works
- [ ] No duplicate scrobbles
---

# Phase 14 — Playlist Import / Export

**Goal:** Import M3U/M3U8/PLS/XSPF. Export to M3U/M3U8.

## Steps

1. **Importers** — parse common formats, match tracks by absolute path → fallback to relative → fallback to title+artist
2. **Exporters** — write M3U with `#EXTINF` lines, configurable absolute vs relative paths
3. **Drag a playlist file onto the app** triggers import
4. **Export from context menu** on any playlist
5. **Round-trip warning** — if a playlist has tracks from multiple folders, relative paths may not work. Warn.
## Tests
- Import each format with fixture files
- Export and re-import round-trips losslessly
- Track matching fallbacks work
- Unicode and weird characters in paths survive
## Acceptance Criteria
- [ ] Import a 200-track M3U from another player
- [ ] Export and open in another player; tracks resolve
---

# Phase 15 — Casting (Google Cast)

**Goal:** Stream audio to Google Cast devices (Chromecast, Nest Audio, Google TV, etc.).

**Reality check:** Chromecast Audio dongles are discontinued but still receive casts. The Google Cast SDK does have macOS support but it's limited compared to iOS. AirPlay 2 may be a more native and frankly more useful target — consider doing AirPlay first.

## Steps

1. **Decide:** Google Cast, AirPlay 2, or both? AirPlay is `AVRoutePickerView` and basically free. Cast SDK is a separate dependency with more setup.
2. **AirPlay 2 first** — drop in `AVRoutePickerView`, AVFoundation handles routing
3. **Google Cast SDK integration:**
   - Add SDK via SPM
   - Discover devices via mDNS
   - Stream encoded audio (MP3/AAC) — need to either re-encode on the fly or only support pre-encoded formats
4. **Gapless on cast** — much harder, depends on receiver capability. May need to accept gaps.
5. **Volume sync** — match local volume to cast device
## Tests
- Mock cast device, verify session lifecycle
- AirPlay routing tests where possible (mostly integration, hard to unit test)
## Acceptance Criteria
- [ ] AirPlay to a HomePod/Apple TV works flawlessly
- [ ] Google Cast to a Nest Audio works (gapless is bonus)
---

# Phase 16 — Distribution & Release

**Goal:** Sign, notarize, distribute. Auto-update.

## Steps

1. **Developer ID signing** — all binaries and frameworks
2. **Notarization** via `notarytool` in CI
3. **DMG packaging** with `create-dmg`, including a nice background image
4. **Sparkle** for auto-updates (if distributing outside App Store) — generates appcasts, signs updates
5. **Crash reporting** — MetricKit gives you most of what you need; consider Sentry if you want richer reporting (privacy-preserving config matters here)
6. **Privacy policy** — required even for outside-App-Store apps if you do any network I/O (you do: cover art, scrobbling, casting)
7. **App icon** — actually good. Treat this like the front door it is.
8. **Website / landing page** — if public release
## Acceptance Criteria
- [ ] Tag a release, GitHub Actions builds and ships a notarized DMG
- [ ] Sparkle picks up new releases
- [ ] First-launch on a clean Mac works without security warnings
---

# Appendix A — Suggested Dependency List

| Package | Purpose | Where |
|---|---|---|
| GRDB.swift | SQLite ORM | Persistence |
| swift-log | Logging facade | Observability |
| SwiftFFmpeg (or custom binding) | Non-native audio formats | AudioEngine |
| TagLib (C++ via bridge) | Tag reading/writing | Metadata |
| swift-snapshot-testing | UI snapshot tests | Tests |
| Sparkle | Auto-updates | App |
| google-cast-sdk | Casting (optional) | Casting module |

---

# Appendix B — How to Drive Claude Code Through This

Rough script per phase:

1. Start a fresh Claude Code session for each phase (don't let context pile up)
2. Open the relevant module folder as the working directory
3. Paste the phase section from this doc
4. Add: "Implement Phase N as specified. Use Context7 for all the listed lookups. Write tests as you go, don't bolt them on after. Commit frequently with conventional commit messages."
5. Run `make test` after every meaningful change. Don't trust "it should work."
6. When the phase is done, run `make lint && make test-coverage` and verify acceptance criteria
7. Open a PR, let CI run, merge, tag if it's a release point
---

# Appendix C — What's Deliberately Out of Scope (For Now)

- iOS / iPadOS companion app — stick with macOS
- Cloud library sync — file-system-watcher + iCloud Drive is enough for v1
- Streaming services (Spotify, Apple Music, Tidal) — different beast entirely
- Podcast support — different metadata model, do as a sequel
- Internet radio — could be a small Phase 17 if you want
- Audio analysis (key detection, BPM auto-detection) — bolt on later if you care
- Acoustic fingerprinting (AcoustID/Chromaprint) — heavy and licence-aware
---

**End of plan. Go forth and build.**
