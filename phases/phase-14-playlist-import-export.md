# Phase 14 — Playlist Import / Export

> Prerequisites: Phases 0–13 complete. Playlist CRUD (Phase 6) and smart playlists (Phase 7) stable.
>
> Read `phases/_standards.md` first.

## Goal

Round-trip playlists with the outside world: M3U/M3U8 (the de-facto standard), PLS, XSPF. Export selected playlists or the whole library. Import via drag-and-drop or menu. Handle relative vs absolute paths gracefully, with a track-match fallback when files aren't at the expected location. Optional CUE sheet support. Optional iTunes/Music Library.xml import (since many users are leaving Apple Music).

## Non-goals

- Apple Music library binary format (`.musiclibrary`) — undocumented, not worth the reversing.
- Streaming-service playlist exports (Spotify/Tidal) — different world.
- Sync with external services — out of scope.

## Outcome shape

```
Modules/Library/Sources/Library/PlaylistIO/
├── PlaylistImportService.swift
├── PlaylistExportService.swift
├── Formats/
│   ├── PlaylistFormat.swift           # Enum: m3u, m3u8, pls, xspf, cue, itunesXML
│   ├── M3UReader.swift
│   ├── M3UWriter.swift                # Writes M3U8 (UTF-8) by default; EXTINF + EXTALB
│   ├── PLSReader.swift
│   ├── PLSWriter.swift
│   ├── XSPFReader.swift
│   ├── XSPFWriter.swift
│   ├── CUESheetReader.swift           # Imports tracks from single-file + CUE pair
│   └── ITunesLibraryReader.swift      # Parses Library.xml (plist)
├── TrackResolver.swift                # Path → Track.ID lookup with fallbacks
├── PathMode.swift                     # .absolute | .relative(to: URL)
└── IOErrors.swift

Modules/UI/Sources/UI/PlaylistIO/
├── ImportSheet.swift
├── ExportSheet.swift
└── ResolutionReviewSheet.swift        # "N tracks couldn't be matched — review?"
```

## Implementation plan

1. **`PlaylistFormat`** enum with file-extension detection and sniffing:
   - `.m3u`/`.m3u8` — first non-blank line `#EXTM3U` → playlist; otherwise treat as bare path list.
   - `.pls` — `[playlist]` header.
   - `.xspf` — XML with `<playlist xmlns="http://xspf.org/ns/0/">`.
   - `.cue` — `FILE "..."` lines + `TRACK` blocks.
   - Apple Music `Library.xml` — plist detected by initial `<?xml` + `<!DOCTYPE plist`.

2. **`M3UReader`**:
   - Line-by-line.
   - `#EXTM3U` marks extended.
   - `#EXTINF:<seconds>,<artist> - <title>` parsed into duration + title guess.
   - `#EXTALB:<album>` applies to the following entry.
   - `#EXTART:<artist>` ditto.
   - Any non-comment line is a path (absolute or relative to the .m3u file's directory).
   - `file://` URLs accepted and converted to filesystem paths.
   - BOM stripped if present; UTF-8 assumed for `.m3u8`, system encoding for `.m3u` (with best-effort fallback via `String(contentsOf:)`).

3. **`M3UWriter`**:
   - Always UTF-8, `.m3u8` extension.
   - `#EXTM3U` header.
   - Per track:
     ```
     #EXTINF:<integer seconds>,<artist> - <title>
     #EXTALB:<album>
     <path>
     ```
   - `PathMode.relative(to: rootURL)` writes relative paths if and only if the track sits under `rootURL`; otherwise falls back to absolute for that row.
   - Line endings: LF (Unix). Writer configuration for CRLF if the user requests Windows compatibility.

4. **`PLSReader` / `PLSWriter`** — key/value, `File<n>=`, `Title<n>=`, `Length<n>=`, `NumberOfEntries=`, `Version=2`.

5. **`XSPFReader` / `XSPFWriter`** — XML. Use `XMLParser` for reading and `XMLDocument` for writing (or string templates — XSPF is small).

6. **`CUESheetReader`** — for single-file rips with a sidecar CUE:
   - Single `FILE` declaration with audio filename.
   - N `TRACK` blocks each with `INDEX 01 mm:ss:ff` (frames at 75fps).
   - Bòcan represents this by treating the audio file as one physical file and creating **virtual tracks** with `start_offset` / `end_offset` columns on `tracks` (add via migration M005 if not present). The `Decoder` must honour start/end when requested.
   - Reader returns `[CUESheetTrack]`; importer creates virtual tracks in the DB.

7. **`ITunesLibraryReader`** — parses the `Library.xml` plist format:
   - Top-level dict with `Tracks` dict (id → track dict) and `Playlists` array.
   - Maps track fields: Name, Artist, Album, Genre, Total Time (ms), Location (file:// URL), Rating (0-100 stepped by 20), Loved (bool), Play Count, Skip Count, Play Date UTC, Date Added.
   - Playlist entries reference Track IDs.
   - Import strategy:
     1. Scan each Library.xml `Tracks.Location` → match to an existing library track by path; if missing, record as an unresolved track and offer to add the file.
     2. Import playlists with matched tracks; write an "iTunes Import <date>" folder in the sidebar.
     3. Optionally import play counts / ratings / dates (setting-gated, default on).
   - Leaves Smart Playlist criteria aside (Apple's binary blob); flag them as "unsupported, review".

8. **`TrackResolver`**:
   - Input: a list of path strings (possibly relative).
   - Steps per entry:
     1. Normalise: expand `~`, resolve relative to the playlist file's directory, canonicalise.
     2. Lookup by exact `file_url` in the DB.
     3. If not found, lookup by `inode` + `device` if the file exists locally.
     4. If not found, fuzzy-match on (artist + title + duration) within tolerance (±2s).
     5. If still not found, mark as unresolved with the parsed metadata for display.
   - Returns `Resolution(resolved: [(index, trackID)], unresolved: [(index, hint: TrackHint)])`.

9. **`ResolutionReviewSheet`**:
   - For unresolved entries, show a table: path, parsed title/artist, candidate matches (if any by partial metadata).
   - Actions per row: pick match, add file (opens picker), skip.
   - Apply to import.

10. **Drag-and-drop import** — dropping a `.m3u8` onto the app or sidebar triggers import directly into a playlist named after the file. Multiple files in one drop → one playlist each, wrapped in a new folder.

11. **Menu commands**:
    - File ▸ Import Playlist… (`⌘⇧O`).
    - File ▸ Import iTunes Library… (separate flow).
    - Playlist context menu ▸ Export… → format picker.
    - Tools ▸ Export All Playlists… → choose folder, writes one file per playlist plus a top-level `index.m3u8`.

12. **Smart playlists on export**:
    - Export as a snapshot (expand current results) by default.
    - Option: "Export as smart description (Bòcan-only)" — writes an XSPF extension with a private namespace carrying the criteria JSON; other apps ignore the extension.

13. **Export path for the library** — "Bòcan Backup" flow: writes all playlists + a CSV of plays and ratings. Not a full backup (DB backup lives in Phase 2), but a readable snapshot.

## Definitions & contracts

### `PlaylistPayload`

```swift
public struct PlaylistPayload: Sendable, Hashable {
    public let name: String
    public let entries: [Entry]
    public struct Entry: Sendable, Hashable {
        public let path: String                 // as written in the source
        public let absoluteURL: URL?            // resolved if possible
        public let durationHint: TimeInterval?
        public let titleHint: String?
        public let artistHint: String?
        public let albumHint: String?
    }
}
```

### `Resolution`

```swift
public struct Resolution: Sendable {
    public struct Match: Sendable { public let entryIndex: Int; public let trackID: Int64 }
    public struct Miss: Sendable { public let entryIndex: Int; public let hint: TrackHint }
    public let matches: [Match]
    public let misses: [Miss]
}
```

## Context7 lookups

- `use context7 M3U M3U8 EXTINF EXTALB format spec`
- `use context7 PLS INI format playlist spec`
- `use context7 XSPF XML namespace playlist`
- `use context7 CUE sheet INDEX 01 FILE WAVE`
- `use context7 Apple iTunes Library.xml plist Tracks Playlists`
- `use context7 Swift XMLParser streaming`

## Dependencies

None new.

## Test plan

- Readers: golden-file fixtures for each format with edge cases:
  - M3U with BOM, CRLF, mixed case extensions, file:// URLs, relative paths one level up.
  - PLS with `NumberOfEntries` wrong → recover.
  - XSPF with tracks containing extensions; namespace variations.
  - CUE with HH:MM:SS:FF > 1h boundaries.
  - iTunes Library.xml — a moderately-sized fixture (50 tracks, 10 playlists).
- Writers: round-trip — read our own export and verify it reconstructs.
- Interop: read playlists from VLC, Music.app exports, Swinsian exports where available; they parse without crashes (failures may be acceptable but must be reported, not swallowed).
- Path mode:
  - Relative export with root chosen → output is portable when target folder is moved with contents.
  - Absolute export preserves hard-coded paths.
  - Mixed library locations → relative-where-possible, absolute otherwise.
- Track resolver:
  - Exact match path hits.
  - Missing file + matching metadata (by artist+title+duration) hits with a lower-confidence marker.
  - Nothing matches → unresolved list populated.
- CUE import creates virtual tracks; playback respects `start_offset/end_offset`.
- iTunes import merges play counts where a match exists (configurable); never duplicates files.
- UI: import review sheet lets me fix an unresolved entry; final playlist has the fix.
- Drag-drop: dropping two `.m3u8` files creates two playlists in a folder.
- Unicode: filenames with NFD/NFC differences resolve identically (normalise before compare).

## Acceptance criteria

- [x] Import an M3U8 written by VLC → matching tracks resolved, unresolved list correct.
- [x] Export a playlist, edit in a text editor, re-import — same contents.
- [ ] iTunes Library.xml import brings in playlists and (optionally) play stats.
- [ ] CUE sheet lets me play individual tracks from a single-file rip.
- [x] Relative export survives moving the root.
- [x] 80%+ coverage on parsers/writers/resolver.
- [x] `make lint && make test-coverage` green.

## Gotchas

- **`.m3u` vs `.m3u8`**: the difference is encoding (Latin-1 vs UTF-8). Default to `.m3u8` for writes; read either and try UTF-8 first, fall back to Windows-1252 with best-effort detection.
- **Relative paths on macOS** with spaces: don't URL-encode in M3U, but handle both encoded and raw on read.
- **CUE sheets** mix file formats (WAV + CUE, FLAC + CUE). FLAC's native cuesheet metadata block is different from sidecar CUE files; handle sidecar first; native cuesheet block parsing is a stretch (defer).
- **Virtual tracks** with offsets require the decoder to support seeking to mid-file; AVFoundation does; FFmpeg decoder must also.
- **iTunes Library.xml plist** can be huge (hundreds of MB). Parse streaming if possible (XMLParser with manual state), not into an `NSDictionary` that balloons memory.
- **Path normalisation**: always compare as `NSString.precomposedStringWithCanonicalMapping`; HFS+/APFS differences have bitten many music apps.
- **Line endings**: parsers accept LF, CRLF, CR; writers default LF; offer CRLF if user exports for Windows.
- **Round-trip loss**: M3U has no notion of playlist folders or accent colour. Export organises folders by writing a subfolder per parent folder of the playlist hierarchy. Import flattens unless an accompanying `index.m3u8` with folder metadata is found.
- **Duplicate playlists on re-import**: detect existing playlist with same name + identical content hash and skip or version-stamp the import; never silently overwrite.
- **file:// URL encoding**: percent-encoded non-ASCII. Decode via `URL(string:)` and `path`.
- **Extensions and UTI**: register the app to open `.m3u`, `.m3u8`, `.pls`, `.xspf` via `Info.plist` `CFBundleDocumentTypes`. Handle "Open With…" correctly.
- **Apple Library.xml is being deprecated** as the default export but users can still produce it via File ▸ Library ▸ Export. Document the steps in the import flow.

## Handoff

Phase 15 (Casting) expects:

- Playlist import isn't a hot path during casting; all I/O happens in its own actor.
- Virtual tracks (from CUE) play through the cast path just as local tracks do; test specifically.
