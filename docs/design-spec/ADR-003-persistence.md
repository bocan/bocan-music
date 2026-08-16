# ADR-003 — Persistence Layer

> Prerequisites: ADR-001 complete. `Observability` available. ADR-002 is independent but can be in progress.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A local SQLite database via GRDB with a full music-library schema, repositories, migrations, reactive observation, and backup hook. **No UI, no scanning, no playback integration.** Just the data layer, thoroughly tested.

## Non-goals

- Scanning files — ADR-004.
- Editing tags — ADR-010.
- Smart-playlist execution — ADR-009 (schema lives here; compiler doesn't).
- Scrobble submission — ADR-029 (queue table lives here; sender doesn't).

## Outcome shape

```
Modules/Persistence/
├── Package.swift
├── Sources/Persistence/
│   ├── Database.swift               # DatabaseQueue/Pool wrapper actor
│   ├── DatabaseLocation.swift       # resolves Application Support path
│   ├── Migrations/
│   │   ├── Migrator.swift
│   │   ├── M001_InitialSchema.swift
│   │   └── (future Mxxx files)
│   ├── Records/
│   │   ├── Track.swift
│   │   ├── Artist.swift
│   │   ├── Album.swift
│   │   ├── Playlist.swift
│   │   ├── PlaylistTrack.swift
│   │   ├── Lyrics.swift
│   │   ├── ScrobbleQueueItem.swift
│   │   ├── CoverArt.swift
│   │   └── Setting.swift            # key/value app settings
│   ├── Repositories/
│   │   ├── TrackRepository.swift
│   │   ├── ArtistRepository.swift
│   │   ├── AlbumRepository.swift
│   │   ├── PlaylistRepository.swift
│   │   ├── LyricsRepository.swift
│   │   ├── ScrobbleRepository.swift
│   │   ├── CoverArtRepository.swift
│   │   └── SettingsRepository.swift
│   ├── Observation/
│   │   ├── AsyncObservation.swift   # ValueObservation -> AsyncSequence bridge
│   │   └── ChangeEvent.swift
│   ├── Backup/
│   │   └── BackupService.swift      # Copy-on-demand to iCloud Drive
│   ├── Errors.swift                 # PersistenceError
│   └── Internal/
│       ├── SQL.swift                # Raw query helpers, FTS builders
│       └── BookmarkBlob.swift       # Security-scoped bookmark wrapper
└── Tests/PersistenceTests/
    ├── MigrationTests.swift
    ├── TrackRepositoryTests.swift
    ├── AlbumRepositoryTests.swift
    ├── PlaylistRepositoryTests.swift
    ├── FTSSearchTests.swift
    ├── CascadeDeleteTests.swift
    ├── ObservationTests.swift
    ├── ConcurrencyTests.swift
    └── PerformanceTests.swift
```

## Implementation plan

1. **Create `Modules/Persistence` Swift Package**, depend on `Observability`.
2. **Add GRDB.swift** via SPM (pin to a recent 6.x or 7.x; note in `DEVELOPMENT.md`).
3. **`DatabaseLocation`** — resolves `~/Library/Application Support/Bocan/library.sqlite`, creates directory if missing, provides `inMemory()` for tests.
4. **`Database`** (actor) — wraps `DatabasePool` (for the real store) or `DatabaseQueue` (for in-memory tests). Applies migrations on init. Enables WAL, foreign keys, recursive triggers, `busy_timeout = 5000`. Exposes read/write closures that return `Sendable` values.
5. **`Migrator`** — registers migrations in order. Every migration has an integer prefix + description. Migrations are **append-only**; never edit one once shipped.
6. **`M001_InitialSchema`** — entire schema from `spec.md` ADR-003, plus:
   - `CREATE TABLE settings (key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)`
   - `CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT)` seeded with `schema_version`, `created_at`, `library_uuid`.
   - All FTS5 triggers (insert/update/delete) to keep `tracks_fts`, `artists_fts`, `albums_fts` in sync with base tables.
   - All indexes listed under "Indexes".
7. **Records** — each table has a `Codable`, `FetchableRecord`, `MutablePersistableRecord`, `Sendable` struct. Use GRDB's `@Column` association where helpful. Timestamps are `Int64` Unix epoch seconds.
8. **Repositories** — only type-level boundary for DB access. Every method is `async` and takes a DB reader/writer from `Database`. All queries parameterised.
9. **Observation** — `AsyncObservation.sequence<T>(_ region:, value:)` returns `AsyncThrowingStream<T, Error>` from a GRDB `ValueObservation`. Use it from SwiftUI in later ADRs.
10. **Backup service** — on demand: snapshots the DB file to `~/Library/Mobile Documents/com~apple~CloudDocs/Bocan/library-<timestamp>.sqlite` if iCloud Drive is available. **Off by default**; gated behind a `Setting` key the UI will flip in ADR-014. Uses SQLite backup API (`sqlite3_backup_*`) via GRDB so it's consistent.
11. **Vacuum policy** — `PRAGMA auto_vacuum = INCREMENTAL` at DB creation; run `PRAGMA incremental_vacuum` on app quit if pending pages > 1 MB. Log.
12. **Encryption** — not in v1. Note in README that the DB is plaintext (so is the Music Library on disk, so this is acceptable). Do not pull in SQLCipher.
13. **Logging** — every repo mutation logs `.debug` with the op name and affected-row count. Every error `.error`.

## Schema additions beyond the spec draft

Add these to `M001_InitialSchema` — they are cheap to add now and painful to add later:

- `tracks.play_duration_total REAL DEFAULT 0` — total seconds played (separate from play_count; useful for scrobbling heuristics and "most listened to" metrics).
- `tracks.skip_after_seconds REAL` — last time a skip happened, for smart-shuffle weighting.
- `tracks.file_path_display TEXT` — a denormalised user-facing path for UI (the security-scoped bookmark isn't readable).
- `tracks.content_hash TEXT` — optional SHA-256 of the audio frames (used to detect duplicates across different paths; computed lazily, not on scan).
- `tracks.disabled BOOLEAN DEFAULT 0` — soft-delete flag for missing files we don't want to forget (preserves ratings, play counts).
- `tracks.album_track_sort_key TEXT` — computed at write time for stable ordering (`printf('%02d.%04d', disc_number, track_number)`).
- `albums.total_tracks INTEGER`, `albums.total_discs INTEGER` — from tags.
- `albums.release_type TEXT` — album/ep/single/compilation/live (MusicBrainz primary type).
- `albums.musicbrainz_release_group_id TEXT` — more useful than release ID for "different pressings of the same album".
- `artists.disambiguation TEXT` — MusicBrainz disambiguation (distinguish "John Williams" composer from "John Williams" guitarist).
- `playlists.parent_id INTEGER REFERENCES playlists(id)` — for playlist folders (ADR-008 nice-to-have).
- `playlists.cover_art_path TEXT` — user-set or auto-derived.
- `cover_art` **table** (rather than just `albums.cover_art_path`):
  ```sql
  CREATE TABLE cover_art (
      hash TEXT PRIMARY KEY,         -- sha256 of image bytes
      path TEXT NOT NULL,            -- cache path
      width INTEGER,
      height INTEGER,
      format TEXT,                   -- jpeg/png/webp
      byte_size INTEGER,
      source TEXT                    -- 'embedded'|'sidecar'|'musicbrainz'|'user'
  );
  ```
  `albums.cover_art_hash` and `tracks.cover_art_hash` reference it. Deletion is reference-counted in repo code.
- `play_history`:
  ```sql
  CREATE TABLE play_history (
      id INTEGER PRIMARY KEY,
      track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
      played_at INTEGER NOT NULL,
      duration_played REAL NOT NULL,
      source TEXT                    -- 'library'|'queue'|'smart'|'airplay'|'cast'
  );
  CREATE INDEX idx_play_history_track ON play_history(track_id);
  CREATE INDEX idx_play_history_played_at ON play_history(played_at DESC);
  ```
  This powers ADR-029's retroactive scrobbles and "Recently Played" smart playlists.

### Indexes

```sql
CREATE INDEX idx_tracks_artist ON tracks(artist_id);
CREATE INDEX idx_tracks_album_artist ON tracks(album_artist_id);
CREATE INDEX idx_tracks_album ON tracks(album_id);
CREATE INDEX idx_tracks_added_at ON tracks(added_at DESC);
CREATE INDEX idx_tracks_last_played ON tracks(last_played_at DESC);
CREATE INDEX idx_tracks_play_count ON tracks(play_count DESC);
CREATE INDEX idx_tracks_rating ON tracks(rating);
CREATE INDEX idx_tracks_genre ON tracks(genre);
CREATE INDEX idx_tracks_year ON tracks(year);
CREATE INDEX idx_tracks_loved ON tracks(loved) WHERE loved = 1;
CREATE INDEX idx_tracks_file_mtime ON tracks(file_mtime);
CREATE UNIQUE INDEX idx_tracks_file_url ON tracks(file_url);
CREATE INDEX idx_pt_track ON playlist_tracks(track_id);
CREATE INDEX idx_scrobble_unsubmitted ON scrobble_queue(submitted) WHERE submitted = 0;
```

### FTS

- `tracks_fts` indexes `title, composer, genre`. Keep `artist` and `album` denormalised in a `virtual` rendered column via triggers so a single FTS query can search all of them.
- Separate `artists_fts(name, sort_name)` and `albums_fts(title)`.
- Use `tokenize='unicode61 remove_diacritics 2'` everywhere.

## Definitions & contracts

### `Database.swift` (sketch)

```swift
public actor Database {
    public enum Location { case application, inMemory, custom(URL) }

    public init(location: Location = .application) async throws

    public func read<T: Sendable>(_ work: @Sendable (GRDB.Database) throws -> T) async throws -> T
    public func write<T: Sendable>(_ work: @Sendable (GRDB.Database) throws -> T) async throws -> T

    public func observe<T: Sendable>(
        region: @escaping @Sendable (GRDB.Database) throws -> DatabaseRegion,
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) -> AsyncThrowingStream<T, Error>

    public func vacuum() async throws
    public func integrityCheck() async throws
    public func schemaVersion() async throws -> Int
}
```

### `PersistenceError`

```swift
public enum PersistenceError: Error, Sendable, CustomStringConvertible {
    case migrationFailed(version: Int, underlying: Error)
    case integrityCheckFailed(details: String)
    case notFound(entity: String, id: Int64)
    case uniqueConstraintViolation(table: String, column: String)
    case foreignKeyViolation(details: String)
    case bookmarkResolutionFailed(reason: String)
    case backupFailed(underlying: Error)
}
```

### Bookmarks

`BookmarkBlob` wraps `Data`, provides `resolve() throws -> URL` that returns a URL with an already-started security scope; caller **must** `stop()` it. Document this contract; ADR-004 uses it heavily.

## Context7 lookups

- `use context7 GRDB.swift DatabasePool migrations`
- `use context7 GRDB.swift ValueObservation AsyncSequence`
- `use context7 GRDB.swift FTS5 triggers`
- `use context7 SQLite WAL auto_vacuum incremental`
- `use context7 Swift 6 Sendable database record`

## Dependencies

- `groue/GRDB.swift` (SPM). Pin the version.
- Nothing else.

## Test plan

- **Migrations**: apply M001 to an empty DB; run `PRAGMA integrity_check`; expect `ok`. For every future migration, test applying to a snapshot of the previous schema.
- **Repositories**: CRUD round-trip for each entity, in-memory DB.
- **Unique constraints**: inserting the same `(title, album_artist_id)` album twice throws `.uniqueConstraintViolation`.
- **Cascade deletes**:
  - Delete album → its tracks' `album_id` set to NULL (tracks survive; user might still want them).
  - Delete playlist → `playlist_tracks` rows gone; tracks untouched.
  - Delete track → `playlist_tracks`, `lyrics`, `scrobble_queue`, `play_history` rows gone.
- **FTS**:
  - Insert tracks with unicode + diacritics (`Björk`, `Sigur Rós`, `Motörhead`); query `bjork`, `sigur ros`, `motorhead` — all match.
  - Insert tracks with Japanese/Korean/Arabic/Hebrew titles; verify substring matches work.
  - `tracks_fts` stays in sync on update and delete (assert via direct SQL inspection).
- **Observation**: subscribe to `tracks` count; insert 5 rows; receive at least 6 values (initial + 5, debounced by GRDB's default policy — test both with and without debounce).
- **Concurrency**: 8 concurrent readers + 2 writers for 1000 ops each; no crashes, no `database is locked` errors, all data present.
- **Performance**:
  - Insert 10,000 tracks in a single transaction in < 5 seconds on an M-series Mac.
  - FTS query across 10k tracks returns in < 50ms.
  - `SELECT * FROM tracks WHERE album_id = ?` with index returns in < 5ms.
- **Backup**: copies DB to target path, resulting file opens cleanly, same row counts.
- **Integrity**: `integrityCheck()` passes on a populated DB.
- **Injection**: supply `'; DROP TABLE tracks; --` as a title; verify table intact and FTS match returns zero rows (parameterisation test).

## Acceptance criteria

- [ ] Empty DB is created at first `Database()` init in Application Support.
- [ ] `schemaVersion()` returns 1.
- [ ] All repositories testable in isolation against in-memory DB.
- [ ] FTS queries unicode-correct.
- [ ] Observation emits updates without leaking Tasks.
- [ ] Coverage ≥ 80%.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **WAL files** (`-wal`, `-shm`) appear beside the DB. Document that backups must copy all three, or use `VACUUM INTO` / SQLite backup API (which produces a single consistent file). Prefer the API.
- **`PRAGMA foreign_keys = ON`** is per-connection. Set in `DatabasePool.configuration.prepareDatabase`.
- **`tracks.rating`** — pick 0–100 (finer grained, future-proof for UIs with half stars); document in a schema comment.
- **Unicode normalisation**: macOS APFS stores filenames in a normalised form. Always call `String.precomposedStringWithCanonicalMapping` before storing `file_url` to avoid phantom duplicates.
- **FTS triggers** must fire on both the real column and the denormalised artist/album columns — easy to miss one and end up with stale indexes. Testing update-then-search catches it.
- **Observation cancellation**: if you return an `AsyncStream` from an actor-owned function, make sure cancelling the consuming `Task` tears down the underlying `ValueObservation`. GRDB's cancellation token needs to be held by the stream's `onTermination`.
- **Backup on iCloud Drive**: the directory might not exist; detect with `FileManager.default.url(forUbiquityContainerIdentifier:)` and log a `.notice` if unavailable rather than throwing.
- **`TEXT` vs `BLOB`** for settings values: pick `BLOB` so you can store arbitrary Codable-encoded data, with a convention that UTF-8 strings are stored as BLOB of UTF-8 bytes.
- **GRDB + Swift 6**: some GRDB closures take `throws` and are `@Sendable`. Pin a version known to be strict-concurrency-friendly; otherwise add `.unsafeFlags(["-strict-concurrency=minimal"])` **only** for the GRDB-importing target as a last resort with a TODO.
- **Schema evolution**: never edit M001 once merged to main. If you notice a problem during ADR-003 development **before** merging, editing M001 is fine — after merge, add M002.

## Handoff

ADR-004 (Scanning) expects:

- `TrackRepository.upsert(_:)` can insert or update by `file_url`, returns the track's `id`.
- `ArtistRepository.findOrCreate(name:)` and `AlbumRepository.findOrCreate(title:albumArtistID:)` are idempotent.
- `CoverArtRepository` handles hash-based dedupe and returns an existing path if an identical image is already stored.
- `BookmarkBlob` exists and round-trips URL ↔ data.
- `Database.observe` works for SwiftUI views (ADR-005).
