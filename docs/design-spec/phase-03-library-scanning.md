# Phase 3 — Library Scanning & Metadata Extraction

> Prerequisites: Phases 0, 1, 2 complete.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Point Bòcan at a folder, walk it, extract every scrap of metadata (tags, cover art, replay gain, lyrics), persist via the Phase 2 repositories, and keep the library in sync as files change on disk. No UI yet — only a programmatic API and a `#if DEBUG` trigger.

## Non-goals

- Browsing the library (Phase 4).
- Editing tags (Phase 8).
- Fetching cover art from the internet (Phase 8).
- Fingerprinting / AcoustID (explicitly out of scope for v1).

## Outcome shape

```
Modules/Metadata/                      # Tag reading/writing
├── Package.swift
├── Sources/Metadata/
│   ├── TagLibBridge/                  # C++ bridge to TagLib
│   │   ├── include/BocanTagLib.h
│   │   └── BocanTagLib.mm             # Objective-C++ thin wrapper
│   ├── TagReader.swift                # Swift facade
│   ├── TagWriter.swift                # (stub; Phase 8 uses it)
│   ├── Tags.swift                     # Sendable DTOs
│   ├── ReplayGain.swift               # parse RG tags
│   ├── CoverArtExtractor.swift
│   ├── LRCParser.swift                # used by Phase 11, defined here
│   └── Errors.swift
└── Tests/MetadataTests/
    ├── TagReaderTests.swift
    ├── CoverArtExtractorTests.swift
    ├── ReplayGainTests.swift
    ├── LRCParserTests.swift
    └── Fixtures/... (tagged audio files)

Modules/Library/                       # Scanning + watching
├── Package.swift
├── Sources/Library/
│   ├── LibraryScanner.swift           # Entry point
│   ├── ScanCoordinator.swift          # Actor orchestrating a scan
│   ├── ScanProgress.swift             # AsyncStream of progress events
│   ├── FileWalker.swift               # Enumerates files respecting sandbox
│   ├── ChangeDetector.swift           # Quick vs full scan logic
│   ├── FSWatcher.swift                # FSEvents wrapper
│   ├── SecurityScope.swift            # Bookmark helpers
│   ├── TrackImporter.swift            # Tags -> repositories
│   ├── CoverArtCache.swift            # On-disk cache in Application Support
│   ├── LibraryLocation.swift          # Root folders + their bookmarks
│   ├── ConflictResolver.swift         # Disk-vs-user-edit policy
│   └── Errors.swift
└── Tests/LibraryTests/
    ├── FileWalkerTests.swift
    ├── ChangeDetectorTests.swift
    ├── TrackImporterTests.swift
    ├── CoverArtDedupeTests.swift
    ├── FSWatcherTests.swift
    ├── SecurityScopeTests.swift
    ├── EdgeCaseTests.swift
    └── Fixtures/sample-library/       # ~50 files, all formats
```

## Implementation plan

1. **Vendor TagLib**. Two viable paths:
   - **Preferred**: static-link TagLib via a system-library SPM target that consumes a prebuilt universal archive (`libtag.a`). Build script `Scripts/build-taglib.sh` downloads a pinned TagLib release, builds arm64 + x86_64, lipo-joins. Archive is cached in CI.
   - **Alternative**: [`SwiftTagger`](https://github.com/NLCtags/SwiftTagger) — simpler but less complete (no APE, no WMA, weaker FLAC). Do not use for v1 because it doesn't cover what we need.
2. **`TagLibBridge`** — minimal Objective-C++ surface so Swift doesn't touch C++ directly. Exposes:
   - `+ (nullable BOCTags *)readTagsFromURL:(NSURL *)url error:(NSError **)error;`
   - `+ (BOOL)writeTags:(BOCTags *)tags toURL:(NSURL *)url error:(NSError **)error;`
   - `+ (nullable BOCCoverArt *)readCoverArtFromURL:...`
   - `BOCTags` is a `@interface` with `NSString *`/`NSNumber *` properties for every field we care about, plus an `NSDictionary *extended` for arbitrary extras (ReplayGain keys etc.).
3. **`TagReader`** — Swift facade. Always called off the main actor. Converts `BOCTags` to a `Sendable` `TrackTags` struct. Does **not** touch the DB.
4. **`TrackTags`** struct — mirrors the columns in `tracks` + `albums` + `artists`. Includes the ReplayGain subvalues, MBIDs, BPM, key, ISRC, and a `[CoverArt]` array (may be zero or many per file — some FLACs carry multiple).
5. **`ReplayGain`** — reads keys `REPLAYGAIN_TRACK_GAIN`, `REPLAYGAIN_TRACK_PEAK`, `REPLAYGAIN_ALBUM_GAIN`, `REPLAYGAIN_ALBUM_PEAK` from the extended dictionary. Normalises "+1.23 dB" / "1.23 dB" / "1.23" strings to `Double`. Also supports R128 opus tags (`R128_TRACK_GAIN` in Q7.8 fixed-point — convert to dB).
6. **`LRCParser`** — parses `[mm:ss.xx]` + the enhanced `<mm:ss.xx>` word-level timing. Returns `SyncedLyrics` (array of `(TimeInterval, String)`). If no timestamps, returns `.unsynced(String)`. Lives in `Metadata` because it's used by scanner (sidecar `.lrc` files) and by Phase 11.
7. **`CoverArtExtractor`** — pulls all embedded images from TagLib, hashes their bytes (`SHA-256`), returns `[ExtractedCoverArt(hash, bytes, mimeType, width, height, source)]`. Priority order for "the album cover" is `Front Cover` picture type → first image.

---

8. **`LibraryLocation`** — app settings table stores a list of root folders. Each root is a `{path, bookmark}` pair. Adding a root:
   - Present `NSOpenPanel` (caller's responsibility; the library module receives the URL).
   - Create a security-scoped bookmark with `.withSecurityScope, .withReadOnlyAccess` (scanning is read-only unless/until Phase 8 writes tags).
   - Persist bookmark in `settings` table.
9. **`SecurityScope`** — `func withAccess<T>(_ bookmark: BookmarkBlob, _ body: (URL) async throws -> T) async throws -> T`. Starts + stops the scope. Every scanner op goes through this. No bare `startAccessingSecurityScopedResource` elsewhere.
10. **`FileWalker`** — `AsyncStream<URL>`. Uses `FileManager.default.enumerator(at:...)` with `.skipsHiddenFiles` and `[.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]` prefetched. Filters by extension allow-list first (cheap), then lets `DecoderFactory`/sniffer validate during import (definitive). Skips:
    - Hidden dotfiles.
    - macOS resource forks / `.DS_Store`.
    - Files inside `.bundle`/`.app`/`.photoslibrary` bundles.
    - Broken symlinks (resolve and `stat`; skip if `ENOENT`).
    - Network volumes that mark themselves unavailable.
    - iCloud-unmaterialised files (`.icloud` placeholders); optionally trigger download via `FileManager.startDownloadingUbiquitousItem` if user setting enabled.
11. **`ChangeDetector`** — for a given URL, compares `(size, mtime)` against the DB's row. Categorises as `new | modified | unchanged`. Also produces the set of `removed` tracks by diffing DB contents with the current walk.
12. **`TrackImporter`** — takes a `TrackTags` + file attributes, upserts into the DB atomically:
    - `findOrCreate` artist(s), album artist, album.
    - Insert/update track.
    - Insert lyrics row if present.
    - For each extracted cover art: call `CoverArtCache.store` (dedupes by hash), link to album (and optionally to the track if different from album).
    - Set `tracks.file_bookmark` to a freshly-created app-scope bookmark of the file URL (so Phase 1 can open it later without re-prompting).
13. **`CoverArtCache`** — stores images at `~/Library/Application Support/Bocan/CoverArt/<sha256 prefix>/<sha256>.<ext>`. Resizes originals > 4096px on the longest side to 4096 using Core Image. Keeps the original bytes separately for the "original" button in Phase 8 if needed.
14. **`ScanCoordinator`** (actor) — orchestrates a scan:
    - Quick scan: walk filesystem, check mtime/size, import new/modified only.
    - Full scan: ignore DB state, re-read every file.
    - Emits `AsyncStream<ScanProgress>` events: `.started`, `.progress(count, total?, currentURL)`, `.imported(trackID)`, `.removed(trackID)`, `.error(URL, Error)`, `.finished(summary)`.
    - Parallelism: `TaskGroup` with concurrency capped at `ProcessInfo.activeProcessorCount` but never more than 4 (disk-bound after a few workers).
    - Runs with cooperative cancellation — cancelling the outer Task cleanly finishes in-flight imports and closes FS access.
15. **`FSWatcher`** — wraps `FSEventStream` (not `DispatchSource`; FSEvents is the right call for recursive folder watching). Coalesces events within 500ms windows. Emits `AsyncStream<FSEvent>`. Re-opens the stream after sleep/wake (receives `NSWorkspace.didWakeNotification`). On event:
    - New/changed file → queue for incremental import.
    - Removed file → mark track `disabled = 1`, do not delete (preserves user data).
    - Atomic renames (common for iTunes-style organisers): detected by same `content_hash` / `(size + leading-bytes hash)`; update `file_url` and `file_bookmark` instead of dropping + re-adding.
16. **`ConflictResolver`** — if a track is `modified` on disk *and* has user-originated edits (tracked by a `tracks.user_edited BOOLEAN DEFAULT 0` flag — add to M001 or as M002 if you already merged), skip the overwrite and emit a conflict event. Phase 8 UI will resolve it. For v1, default policy: "user edits win, log a warning".
17. **Permissions** — if a root path becomes inaccessible (user moved it, drive unmounted), mark the root `inaccessible = 1`, emit a structured warning, and continue with other roots.

## Definitions & contracts

### `ScanProgress`

```swift
public enum ScanProgress: Sendable {
    case started(rootCount: Int)
    case walking(currentPath: String, walked: Int)
    case processed(url: URL, outcome: ImportOutcome)
    case removed(trackID: Int64)
    case error(url: URL?, error: Error)
    case finished(Summary)

    public enum ImportOutcome: Sendable {
        case inserted(trackID: Int64)
        case updated(trackID: Int64)
        case skippedUnchanged
        case conflict(trackID: Int64)
    }

    public struct Summary: Sendable {
        public let inserted: Int
        public let updated: Int
        public let removed: Int
        public let skipped: Int
        public let errors: Int
        public let duration: Duration
    }
}
```

### `LibraryScanner` (public entry)

```swift
public actor LibraryScanner {
    public init(database: Database, logger: AppLogger = .make(.library))
    public func addRoot(_ url: URL) async throws
    public func removeRoot(id: Int64) async throws
    public func roots() async throws -> [LibraryRoot]
    public func scan(mode: ScanMode = .quick) -> AsyncStream<ScanProgress>
    public func startWatching() async
    public func stopWatching() async
}
```

## Context7 lookups

- `use context7 FSEventStreamCreate Swift coalesced`
- `use context7 Swift security-scoped bookmark sandbox`
- `use context7 Swift FileManager enumerator prefetched keys`
- `use context7 Swift TaskGroup throwing bounded concurrency`
- `use context7 TagLib macOS static build lipo`
- `use context7 Swift NSWorkspace did wake notification`
- `use context7 iCloud startDownloadingUbiquitousItem Swift`

## Dependencies

- TagLib (static, self-built or vendored prebuilt).
- No Swift-level new deps.
- Homebrew: nothing new (FFmpeg is already there for format sniffing fallbacks if needed).

## Test plan

### Fixture library

Commit a small fixture library under `Modules/Library/Tests/LibraryTests/Fixtures/sample-library/` covering:

- Formats: MP3 (ID3v1, ID3v2.3, ID3v2.4), M4A (AAC + ALAC), FLAC, OGG Vorbis, Opus, WAV with INFO chunk, DSF, APE, WMA, WavPack.
- Tag edge cases: ID3 with UTF-16 BE/LE, unsynchronized ID3 frames, tags with embedded NULs, genre as numeric code, missing required tags, multi-value artists (`artist1;artist2`), composers, BPM as float.
- Cover art: embedded JPEG, embedded PNG, embedded WebP, multiple embedded images (one front, one back), sidecar `cover.jpg`.
- Lyrics: embedded USLT, embedded SYLT, sidecar `.lrc`.
- Replay Gain: files with full RG tagging, R128 Opus tags, files without.
- Multi-disc albums (disc 1 + disc 2 tracks in subfolders).
- Compilation album (`albumartist` = "Various Artists").
- Unicode hell: filenames with emoji, Arabic, Hebrew, combining characters, zero-width joiners.
- Broken cases: truncated MP3, FLAC with corrupt metadata block (scanner should skip + log, not crash).

Fixtures that are large or binary-awkward can be generated at CI time by `Scripts/gen-library-fixtures.sh` using FFmpeg and a pinned set of CC0 inputs.

### Tests

- **`TagReader`** — every fixture: expected fields present, encodings decoded correctly.
- **`LRCParser`** — covers `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`, `[offset:±n]`, multiple timestamps per line, malformed lines (skipped, not fatal).
- **`ReplayGain`** — parses "+1.23 dB" / "1.23" / R128 Q7.8.
- **`CoverArtExtractor`** — returns all embedded images; respects front-cover priority.
- **`FileWalker`** — skips hidden, skips bundles, skips broken symlinks, surfaces unsupported filenames.
- **`ChangeDetector`** — detects new / modified / unchanged / removed across two synthesised DB states.
- **`TrackImporter`** — idempotent: import the same file twice → one row, `updated_at` changes only on real changes.
- **Dedupe** — same image embedded in 12 tracks stores one cache file, reference count via repo query equals 12.
- **`ScanCoordinator`** — full scan of the fixture library in < 5s on an M-series Mac; summary counts correct.
- **`FSWatcher`** — touch a file, event arrives within 2s; delete → delete event; rapid burst of changes coalesces.
- **Conflict**: simulate a disk change on a track with `user_edited = 1` → `ImportOutcome.conflict` emitted; DB row not overwritten.
- **Security scope**: round-trip bookmark across a synthetic app restart (serialise + deserialise bookmark data, re-resolve URL, read file).
- **iCloud placeholder**: simulate `.icloud` extension; scanner emits a `notice` and, if download setting is on, calls `startDownloadingUbiquitousItem` (mocked).
- **Performance**: scan a 10,000-file synthetic library in < 60s; memory stays < 500 MB.
- **Cancellation**: start a scan, cancel after 100 imports, assert we stop within 500ms and emit no events afterwards.
- **Permission loss**: delete root dir during scan → scan completes with errors logged, does not crash.

## Acceptance criteria

- [ ] `LibraryScanner.addRoot(_:)` persists a bookmark and survives a simulated restart.
- [ ] Quick scan over fixture library produces correct DB state.
- [ ] Full scan produces identical DB state to quick scan on a clean DB.
- [ ] Adding a file to a watched folder results in the track appearing without manual rescan.
- [ ] Removing a file results in `tracks.disabled = 1` (not deletion).
- [ ] Cover art extracted, deduped by hash, stored once per unique image.
- [ ] Lyrics extracted (embedded + sidecar) and persisted.
- [ ] 80%+ coverage across `Metadata` and `Library`.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **TagLib + C++ exceptions**: wrap every call site in try/catch inside the Obj-C++ bridge and map to `NSError`. An uncaught C++ exception crossing back into Swift is UB.
- **ID3v2 text encodings**: Latin-1, UTF-16 with/without BOM, UTF-8. TagLib usually handles them, but some files lie about their encoding. Add a fallback: if the decoded string contains `U+FFFD`, try the other common encoding before accepting garbage.
- **Multi-valued tags**: Vorbis comments and ID3v2.4 can have multiple values for one key. Preserve them; `artist` column stores primary, keep the rest in a sidecar `track_artists` table? For v1, join with `;` and keep a raw copy in `tracks.extended_tags` JSON. Decide and document.
- **FSEvents + case-insensitive HFS/APFS**: events give you the path the OS stored. Normalise to NFC before comparing with DB `file_url`.
- **Atomic renames**: many tools write to `song.tmp` then `mv song.tmp song.mp3`. FSEvents may deliver a "file created" + a "file deleted" in either order. Coalesce within the 500ms window and match by inode (`URLResourceValues.fileResourceIdentifier`) when possible.
- **Security scope leaks**: every `startAccessingSecurityScopedResource` must be paired with `stop`. `defer` it. A leak here will eventually exhaust handles and break scanning silently.
- **Network volumes**: SMB/AFP mounts can hang `stat`. Use `URLResourceValues` with a timeout; if nothing in 5s, treat as inaccessible.
- **Sandbox + FSEvents** interact weirdly. You need to hold the security-scoped URL open for the duration of the watch. Store the bookmark-resolved URL alongside the `FSEventStream` and release it only when watching stops.
- **Thumbnail generation** for cover art uses Core Image. Core Image on `.png` with odd colour profiles has produced glitches historically — test with weird inputs.
- **Large MP4 boxes**: some M4A files have moov atoms at the end. TagLib reads them fine but may slow-scan network files. Pre-buffering is only a concern for NAS; document.
- **DSF/DFF tags**: minimal standard — mostly have just title/artist/album. Missing tags is the common case, not an error.
- **`tracks.file_url`** should be the canonical absolute path (NFC), not a `file://` URL string. Pick one convention and stick to it.
- **Opus + R128**: `R128_TRACK_GAIN` is relative to −23 LUFS, expressed in Q7.8 fixed-point integer. Convert via `Double(raw) / 256.0` → dB; then add the "pre-gain" offset of −5 dB for typical playback alignment (or don't, and document the convention). Phase 9 re-uses this.

## Handoff

Phase 4 (Library UI) expects:

- `LibraryScanner` can be instantiated and driven from SwiftUI.
- `ScanProgress` stream is `@MainActor`-friendly when bridged.
- Every row in `tracks` has a valid bookmark usable by the `AudioEngine` to open the file.
- `CoverArtCache` paths are stable and readable from the UI (via `NSImage(contentsOf:)`).
- `play_history`, `scrobble_queue`, `lyrics`, `cover_art` tables are populated or populatable in realistic shape.
