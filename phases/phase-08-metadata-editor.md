# Phase 8 — Metadata Editor & Cover Art Fetching

> Prerequisites: Phases 0–7 complete. TagLib bridge (Phase 3) includes writing support.
>
> Read `phases/_standards.md` first.

## Goal

Edit metadata in-app: single-track and multi-track edit modes, write-back to files, auto-fetch missing cover art from MusicBrainz / Cover Art Archive, and batch operations. Safe, reversible, never destructive without confirmation.

## Non-goals

- Acoustic fingerprinting / AcoustID — we'll build this in Phase 8.5.
- Auto-tagging entire libraries from nothing — out of scope.
- Lyric fetching — Phase 11 (note: keep architecture compatible).
- Discogs / fanart.tv integration — optional stretch, not required.

## Outcome shape

```
Modules/Metadata/Sources/Metadata/
└── (TagWriter.swift is fleshed out here)

Modules/Library/Sources/Library/Edit/
├── MetadataEditService.swift           # Orchestrator
├── EditTransaction.swift               # Atomic write (file + DB + cover cache)
├── TagDiff.swift                       # Multi-track "changed fields only"
└── BackupRing.swift                    # Undo (keeps a copy of the original tags for N edits)

Modules/Library/Sources/Library/CoverArt/
├── CoverArtFetcher.swift               # Protocol
├── MusicBrainzClient.swift
├── CoverArtArchiveClient.swift
├── CoverArtSearchService.swift         # Combines the above
└── RateLimiter.swift                   # 1 req/sec MB compliance

Modules/UI/Sources/UI/MetadataEditor/
├── TagEditorSheet.swift                # Sheet UI, single + multi
├── TagFieldRow.swift                   # Label + input + <various> state
├── ArtworkEditor.swift                 # Drag/drop, paste, fetch, crop
├── CoverArtFetchSheet.swift            # Search + results picker
└── ViewModels/
    ├── TagEditorViewModel.swift
    └── CoverArtFetchViewModel.swift

Tests per module.
```

## Implementation plan

### Metadata editing

1. **`TagWriter`** (in `Metadata`) — wraps the TagLib bridge write path. Writes are **atomic at the file level**: write to a temp file beside the original, `fsync`, then `rename` over the original. On failure, the original is untouched.

2. **Single-track edit sheet** — opens via `⌘I` / "Get Info" / context menu. Fields:
   - Core: title, artist, album artist, album, track #, disc #, year, genre, composer.
   - Extended: BPM, key, ISRC, comment.
   - Flags: loved, excluded_from_shuffle, rating.
   - Lyrics: multi-line text, toggle synced if `[mm:ss]` detected.
   - Sorting names: sort_artist, sort_album_artist, sort_album (normally hidden under "More…").
   - Tabs/sections: **Details**, **Artwork**, **Lyrics**, **File Info (read-only)**, **Sorting**, **Advanced**.

3. **Multi-track edit sheet** — activated when > 1 track is selected.
   - Each field shows either a common value or the placeholder `<various>` in faint text.
   - Changing a field (even clearing to empty string) marks it as "will be applied to all selected". A checkbox next to each field toggles whether to apply; editing implicitly ticks it.
   - Special rules:
     - Track number is disabled in multi-edit (rarely makes sense across many tracks).
     - Rating/loved apply to all.
     - Artwork, if changed, applies to all.
   - Bulk-only helpers:
     - "Renumber track numbers in current sort order."
     - "Set album artist to current artist."
     - "Title Case / UPPER / lower" buttons for text fields.

4. **`TagDiff`** — produces a minimal patch (only the fields the user actually changed). Multi-edit writes one patch to N files.

5. **`EditTransaction`**:
   - Gather patches per file.
   - For each file:
     1. Start security scope.
     2. Back up current tags to `BackupRing`.
     3. Write new tags via `TagWriter`.
     4. Re-read tags to confirm persistence.
     5. Update DB row via repositories (in a single DB transaction across all files).
     6. Invalidate cover art cache entries for touched tracks.
   - On any failure, the whole operation rolls back — restore files from `BackupRing`, DB tx rolls back.
   - Progress reporter for large batches (SwiftUI sheet shows a progress ring).

6. **`BackupRing`** — ring buffer of the last N edits on disk (say 50). Each entry stores the original tags JSON keyed by `{file_url, edit_id}`. On undo (`⌘Z` after edit), restore from the ring.

7. **User-edited flag** — after any successful edit, set `tracks.user_edited = 1` so Phase 3's scanner respects user priority on next scan.

8. **Conflict resolution** — when the scanner's `ConflictResolver` flagged a track (Phase 3), the editor sheet shows a banner: "This file was changed on disk after your last edit." with buttons "Keep my edits", "Take disk version", "Show diff". The diff is a side-by-side field comparison.

### Cover art

9. **`CoverArtFetcher` protocol**:
   ```swift
   public protocol CoverArtFetcher: Sendable {
       func search(artist: String, album: String) async throws -> [CoverArtCandidate]
       func image(for candidate: CoverArtCandidate, size: CoverArtSize) async throws -> Data
   }
   ```

10. **`MusicBrainzClient`**:
    - Base URL: `https://musicbrainz.org/ws/2/`.
    - `User-Agent` **required**: `Bocan/<version> ( https://bocan.app )` — document; no real URL yet is fine, but put a contact email per MB guidelines.
    - Use `release-group` lookup first (better matching across pressings), fall back to `release` search if needed.
    - Parse the JSON response with `Decodable`; never use XML.

11. **`CoverArtArchiveClient`**:
    - Base: `https://coverartarchive.org/`.
    - For each candidate release/release-group, fetch `/<type>/<mbid>` for the index, then pull the `front` image. Accept redirects to Archive.org.
    - Download full-resolution by default; also offer a 500px thumbnail for preview.

12. **`RateLimiter`** — token bucket, 1 request per second to MusicBrainz. Cover Art Archive is on Archive.org (no strict limit) but be polite (2/sec max).

13. **`CoverArtSearchService`**:
    - Input: artist + album (strings).
    - Strategy: try MB release-group search → fetch CAA for each result → return candidates with thumbnails.
    - Cache search results for 24h in memory; cache thumbnails on disk in a separate folder from the main cache (so they're evictable without losing existing art).

14. **Cover art UI**:
    - `ArtworkEditor` pane in the tag editor:
      - Current art visible at 1:1.
      - Buttons: "Choose File…", "Paste", "Fetch…", "Remove".
      - Drag-drop onto the view accepts images.
      - On set: image is normalised (strip EXIF, convert to sRGB JPEG quality 90 if > 1 MB and current format is PNG/WebP; keep original bytes otherwise), stored in cover cache, linked via `albums.cover_art_hash`.
    - `CoverArtFetchSheet`: search field pre-populated from selected track's artist/album, result grid with thumbnails, badge for source (MB/CAA), "Apply to Album" / "Apply to Selected Tracks" actions.

15. **Embed vs cache-only** — setting `metadata.embedCoverArt` (default: off in v1, opt-in). When off, cover art is stored only in the app cache (fast, doesn't modify files). When on, changing art rewrites the file and embeds the image.

### Batch operations (bonus)

16. **Tools menu**:
    - "Fetch Missing Cover Art for Library" — finds albums with no `cover_art_hash`, runs the fetcher one at a time (rate-limited), reports progress.
    - "Find Duplicates by Tag" — groups by `(title, artist, duration rounded to second)`; presents a side-by-side reviewer; user picks survivors.
    - "Recompute ReplayGain" (forwards to Phase 9 if available, otherwise disabled) — hook present in UI, logic may be stubbed here.

## Definitions & contracts

### `TrackTagPatch`

```swift
public struct TrackTagPatch: Sendable, Codable, Hashable {
    public var title: String??               // nil = unchanged, .some(nil) = clear
    public var artist: String??
    public var albumArtist: String??
    public var album: String??
    public var trackNumber: Int??
    public var discNumber: Int??
    public var year: Int??
    public var genre: String??
    public var composer: String??
    public var bpm: Double??
    public var key: String??
    public var isrc: String??
    public var comment: String??
    public var lyrics: String??
    public var syncedLyrics: SyncedLyrics??
    public var coverArt: Data??              // raw bytes, or `.some(nil)` to clear
    public var rating: Int??
    public var loved: Bool?
    public var excludedFromShuffle: Bool?
    public var sortArtist: String??
    public var sortAlbumArtist: String??
    public var sortAlbum: String??
}
```

### `CoverArtCandidate`

```swift
public struct CoverArtCandidate: Sendable, Hashable, Identifiable {
    public let id: String                    // MBID or archive identifier
    public let releaseGroupID: String?
    public let releaseID: String?
    public let title: String
    public let artist: String
    public let year: Int?
    public let thumbnailURL: URL
    public let fullURL: URL
    public let dimensions: CGSize?
    public let source: Source
    public enum Source: String, Sendable { case musicbrainz, coverArtArchive }
}
```

## Context7 lookups

- `use context7 MusicBrainz API release-group search JSON`
- `use context7 Cover Art Archive API front thumb`
- `use context7 URLSession async throws rate limit`
- `use context7 Swift atomic file write rename fsync`
- `use context7 SwiftUI Form sheet validation multi select`
- `use context7 Core Image sRGB export JPEG`

## Dependencies

None new at the Swift level. Keep HTTP pure `URLSession`.

## Test plan

### Editor

- Round-trip: edit a tag, save, reread from disk, verify.
- Multi-edit writes only changed fields: set up 3 files with distinct artists; edit the album only; confirm artists preserved.
- Undo restores original tags (re-read from disk matches pre-edit).
- Atomic write: simulate a failure between temp write and rename → original file untouched and DB unchanged.
- DB and file stay in sync: after save, `TrackRepository.findByFileURL` returns the new values.
- User-edited flag set after a successful edit.

### Cover art

- MusicBrainz client: mock HTTP response (JSON fixture), parse candidates, respect 1/sec rate limit (test the limiter with a fake clock).
- Cover Art Archive client: mock redirect chain ending at archive.org.
- Fetch flow: search → candidates rendered → user picks → image downloaded → normalised → cached → linked to album.
- Failed network: offline mode degrades to "no results", never crashes.
- Applying art to album updates all tracks sharing the album; applying to a track only updates that row.
- Cache dedupe: fetching the same image (byte-identical) twice stores once.

### Batch

- "Fetch missing" runs through N albums without exceeding rate limit; progress events correct; cancellation responsive.
- Duplicate finder groups correctly; acting on a group removes the losers from the library (soft delete via `disabled=1`, not a hard delete unless user confirms).

### Security

- Never include sensitive data in logs (API keys, cookies). Verify `AppLogger` redaction applies to URLSession request/response logging helpers.

### Performance

- Batch edit 500 tracks in < 30s on an M-series Mac.

## Acceptance criteria

- [ ] Fix a typo in one artist name across 12 tracks in a single sheet.
- [ ] Auto-fetch cover art for an album that's missing it; pick one; it applies.
- [ ] Paste an image from the clipboard onto an album → shows up everywhere.
- [ ] Undo restores previous tag values.
- [ ] 80%+ coverage on new code.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **TagLib Unicode writes**: ID3v2.4 should default to UTF-8. Configure the writer explicitly; don't rely on defaults that vary between TagLib versions.
- **Vorbis comments are case-insensitive**: when writing, use canonical uppercase keys (`TITLE`, `ARTIST`) to match community tools.
- **ID3v2 vs v1 coexistence**: writing v2 may leave stale v1 tags. Strip v1 on write (configurable; default yes).
- **File permissions**: some files may be read-only (e.g. NAS mounts). Detect `EACCES` and surface a clear error; don't silently fail.
- **Atomic rename across volumes**: `rename(2)` is atomic only within the same filesystem. If the temp is on a different volume (e.g. `/tmp` ≠ user drive), write the temp beside the target.
- **Cover art round-tripping**: some players embed a low-res copy + high-res sidecar. Respect existing high-res art if present — editing shouldn't downgrade silently.
- **MusicBrainz rate limit** is enforced by their server with `503 Retry-After`. Honour `Retry-After` headers on top of the client-side limiter.
- **User-Agent**: MB blocks requests without a proper User-Agent. Always include version + contact info.
- **Localisation of rating UI**: 0–100 under the hood, display as 0–5 stars (half increments). Make sure multi-edit distinguishes "no rating" from "rating 0".
- **Multi-edit placeholder `<various>`** must be localised. No hardcoded English string.
- **Embed cover art into Opus**: `METADATA_BLOCK_PICTURE` base64 in Vorbis comment, not a direct APIC-like frame. TagLib abstracts this, but test.
- **Conflict diff display**: be clear what "disk" means — the file's tags, not the filesystem path.

## Handoff

Phase 9 (EQ) expects:

- Editing `replaygain_track_gain` / `replaygain_album_gain` fields exists through the patch type (advanced section). Phase 9 will populate these when computing ReplayGain.
- `hasCoverArt` and `hasLyrics` derived booleans in the DB update correctly on save (for smart-playlist rules).
