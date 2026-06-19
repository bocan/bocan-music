# Phase 21-1: Podcasts - Persistence (schema, records, repositories)

> Depends on: `phase21-0-overview.md` (read it first; the table shapes and the
> "state is a separate table" rationale live there). No other Phase 21 file is a
> prerequisite. This slice touches only the **Persistence** module.
>
> Provides, for later phases: the `M023_Podcasts` migration; the `Podcast`,
> `PodcastEpisode`, `PodcastEpisodeState` records; the `EpisodeListItem` read
> model; and `PodcastRepository`, `EpisodeRepository`, `EpisodeStateRepository`.

## Goal

Add the three podcast tables and the GRDB records + repositories the rest of
Phase 21 builds on. Follow the existing Persistence conventions exactly
(`M020_SubsonicServers.swift` is the closest precedent for new tables; the
`TrackRepository` / `LyricsRepository` pair is the precedent for repository
shape).

## Non-goals

- No FTS for podcasts in this slice. The local library is small; the UI filters
  the subscribed-show list and the per-show episode list with simple `LIKE`
  predicates (phase 21-9). A full-text index can be a later add if it is ever
  warranted.
- No business logic (subscribe/refresh/dedupe). That is the `Podcasts` module
  (phases 21-2, 21-4). This slice is pure storage.

## Outcome shape

```
Modules/Persistence/Sources/Persistence/
├── Migrations/
│   └── M023_Podcasts.swift              # new tables + indexes
├── Records/
│   ├── Podcast.swift                    # podcasts row
│   ├── PodcastEpisode.swift             # podcast_episodes row
│   └── PodcastEpisodeState.swift        # podcast_episode_state row
├── Repositories/
│   ├── PodcastRepository.swift
│   ├── EpisodeRepository.swift
│   └── EpisodeStateRepository.swift
└── (EpisodeListItem can live in Records/EpisodeListItem.swift)

Modules/Persistence/Tests/PersistenceTests/
├── PodcastRepositoryTests.swift
├── EpisodeRepositoryTests.swift
└── EpisodeStateRepositoryTests.swift
```

## Migration

Create `M023_Podcasts.swift`. **Verify the ceiling first**: open
`Migrations/Migrator.swift`, find the highest `MNNN…register(in: &dm)` line
(currently `M022ScrobbleIgnoredRollup`), and use the next integer. If new
migrations landed since this spec was written, bump accordingly; never reuse or
renumber an existing migration.

Follow the `M020_SubsonicServers.swift` pattern (enum with a static
`register(in:)`, raw `db.execute(sql:)` for `CREATE TABLE` / indexes). Use the
exact SQL from `phase21-0-overview.md` ("Data model"). Then register it in
`Migrator.make()` after the current last line:

```swift
// in Migrator.make(), after M022ScrobbleIgnoredRollup.register(in: &dm)
M023Podcasts.register(in: &dm)
```

```swift
import GRDB

enum M023Podcasts {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("023_podcasts") { db in
            try db.execute(sql: """
                CREATE TABLE podcasts (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    feed_url              TEXT NOT NULL,
                    title                 TEXT NOT NULL,
                    author                TEXT,
                    description           TEXT,
                    artwork_url           TEXT,
                    artwork_path          TEXT,
                    link                  TEXT,
                    language              TEXT,
                    explicit              INTEGER NOT NULL DEFAULT 0,
                    categories_json       BLOB,
                    owner_name            TEXT,
                    owner_email           TEXT,
                    copyright             TEXT,
                    funding_url           TEXT,
                    itunes_collection_id  INTEGER,
                    podcast_index_id      INTEGER,
                    http_etag             TEXT,
                    http_last_modified    TEXT,
                    last_refreshed_at     REAL,
                    last_refresh_error    TEXT,
                    subscribed            INTEGER NOT NULL DEFAULT 1,
                    auto_download         INTEGER NOT NULL DEFAULT 0,
                    sort_index            INTEGER NOT NULL DEFAULT 0,
                    added_at              REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE UNIQUE INDEX podcasts_feed_url_idx ON podcasts(feed_url)")

            try db.execute(sql: """
                CREATE TABLE podcast_episodes (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    podcast_id        INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
                    guid              TEXT NOT NULL,
                    title             TEXT NOT NULL,
                    subtitle          TEXT,
                    description_html  TEXT,
                    audio_url         TEXT NOT NULL,
                    audio_mime        TEXT,
                    audio_byte_length INTEGER,
                    duration          REAL,
                    published_at      REAL,
                    season            INTEGER,
                    episode_number    INTEGER,
                    episode_type      TEXT,
                    artwork_url       TEXT,
                    artwork_path      TEXT,
                    chapters_url      TEXT,
                    transcript_url    TEXT,
                    link              TEXT,
                    explicit          INTEGER NOT NULL DEFAULT 0,
                    added_at          REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE UNIQUE INDEX podcast_episodes_guid_idx ON podcast_episodes(podcast_id, guid)")
            try db.execute(sql: "CREATE INDEX podcast_episodes_published_idx ON podcast_episodes(podcast_id, published_at DESC)")

            try db.execute(sql: """
                CREATE TABLE podcast_episode_state (
                    podcast_id     INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
                    guid           TEXT NOT NULL,
                    play_position  REAL NOT NULL DEFAULT 0,
                    play_state     TEXT NOT NULL DEFAULT 'unplayed',
                    last_played_at REAL,
                    completed_at   REAL,
                    download_state TEXT NOT NULL DEFAULT 'none',
                    download_path  TEXT,
                    download_bytes INTEGER,
                    PRIMARY KEY (podcast_id, guid)
                )
            """)
        }
    }
}
```

## Records

Mirror the `Track` / `Lyrics` record style: `Codable, FetchableRecord,
MutablePersistableRecord, Sendable`, a `static let databaseTableName`,
`CodingKeys` mapping camelCase to snake_case, and `didInsert` to capture the
generated row id.

### `Podcast`

```swift
public struct Podcast: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "podcasts"

    public var id: Int64?
    public var feedURL: String
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: String?
    public var artworkPath: String?
    public var link: String?
    public var language: String?
    public var explicit: Bool
    public var categoriesJSON: Data?
    public var ownerName: String?
    public var ownerEmail: String?
    public var copyright: String?
    public var fundingURL: String?
    public var itunesCollectionID: Int64?
    public var podcastIndexID: Int64?
    public var httpETag: String?
    public var httpLastModified: String?
    public var lastRefreshedAt: Double?
    public var lastRefreshError: String?
    public var subscribed: Bool
    public var autoDownload: Bool
    public var sortIndex: Int
    public var addedAt: Double

    public init( /* all properties; sensible defaults: explicit=false,
                    subscribed=true, autoDownload=false, sortIndex=0 */ ) { /* … */ }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feedURL = "feed_url"
        case title
        case author
        case description
        case artworkURL = "artwork_url"
        case artworkPath = "artwork_path"
        case link
        case language
        case explicit
        case categoriesJSON = "categories_json"
        case ownerName = "owner_name"
        case ownerEmail = "owner_email"
        case copyright
        case fundingURL = "funding_url"
        case itunesCollectionID = "itunes_collection_id"
        case podcastIndexID = "podcast_index_id"
        case httpETag = "http_etag"
        case httpLastModified = "http_last_modified"
        case lastRefreshedAt = "last_refreshed_at"
        case lastRefreshError = "last_refresh_error"
        case subscribed
        case autoDownload = "auto_download"
        case sortIndex = "sort_index"
        case addedAt = "added_at"
    }
}
```

### `PodcastEpisode`

Same conventions. Properties map the `podcast_episodes` columns:
`id, podcastID (podcast_id), guid, title, subtitle, descriptionHTML
(description_html), audioURL (audio_url), audioMIME (audio_mime),
audioByteLength (audio_byte_length), duration, publishedAt (published_at),
season, episodeNumber (episode_number), episodeType (episode_type), artworkURL
(artwork_url), artworkPath (artwork_path), chaptersURL (chapters_url),
transcriptURL (transcript_url), link, explicit, addedAt (added_at)`. Include
`didInsert`.

### `PodcastEpisodeState`

Composite primary key `(podcast_id, guid)`, so there is no auto-increment id and
no `didInsert`. Use `PersistableRecord` (not `Mutable…`) like `Lyrics`. Map
`play_state` and `download_state` to the `EpisodePlayState` /
`EpisodeDownloadState` enums (store their `rawValue` strings). Properties:
`podcastID, guid, playPosition, playState, lastPlayedAt, completedAt,
downloadState, downloadPath, downloadBytes`.

### `EpisodeListItem` (read model)

Exactly as defined in `phase21-0-overview.md`. It is not a GRDB record; it is the
joined value the repositories assemble and the UI renders. Put the enums
(`EpisodePlayState`, `EpisodeDownloadState`) here or in their own small file so
both the records and the UI can use them.

## Repositories

`struct …: Sendable`, holding `private let database: Database` and
`private let log = AppLogger.make(.persistence)`, with `async throws` methods
wrapping `database.read`/`database.write` and `database.observe`. Throw
`PersistenceError.notFound(entity:id:)` for required-but-missing rows; return
optionals for lookups that may legitimately be empty.

### `PodcastRepository`

```swift
public struct PodcastRepository: Sendable {
    public init(database: Database)

    // Write
    @discardableResult public func insert(_ podcast: Podcast) async throws -> Int64
    public func update(_ podcast: Podcast) async throws
    /// Insert or update keyed on the unique feed_url. Returns the row id.
    @discardableResult public func upsertByFeedURL(_ podcast: Podcast) async throws -> Int64
    public func delete(id: Int64) async throws                 // cascades to episodes + state
    public func setSortIndex(id: Int64, sortIndex: Int) async throws

    // Read
    public func fetch(id: Int64) async throws -> Podcast
    public func fetchByFeedURL(_ feedURL: String) async throws -> Podcast?
    public func fetchAllSubscribed() async throws -> [Podcast]  // WHERE subscribed = 1 ORDER BY sort_index, title
    /// Podcasts whose last_refreshed_at is older than `interval` (or NULL).
    public func fetchStale(olderThan interval: TimeInterval, now: Double) async throws -> [Podcast]

    // Observation - drives the subscribed-shows grid live
    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
}
```

`upsertByFeedURL` must **preserve** `id`, `added_at`, `subscribed`,
`auto_download`, and `sort_index` when a row already exists, and update the
feed-derived fields (title, author, artwork, etag, etc.). The simplest robust
form: `fetchByFeedURL`; if present, copy the preserved fields from the existing
row onto the incoming value, set its `id`, and `update`; else `insert`.

### `EpisodeRepository`

```swift
public struct EpisodeRepository: Sendable {
    public init(database: Database)

    // Write - content only; never touches state
    /// Upsert keyed on (podcast_id, guid). Insert new, update existing content
    /// columns. Returns the row id.
    @discardableResult public func upsert(_ episode: PodcastEpisode) async throws -> Int64
    /// Bulk upsert in one transaction (used by refresh).
    public func upsertAll(_ episodes: [PodcastEpisode]) async throws
    /// Delete content rows for a podcast whose guid is not in `keepGUIDs`
    /// (used by an optional pruning policy). State rows are NOT deleted here.
    public func pruneEpisodes(podcastID: Int64, keepGUIDs: Set<String>) async throws

    // Read
    public func fetch(id: Int64) async throws -> PodcastEpisode
    public func fetchByGUID(podcastID: Int64, guid: String) async throws -> PodcastEpisode?
    public func fetchForPodcast(podcastID: Int64) async throws -> [PodcastEpisode] // ORDER BY published_at DESC

    // Joined read model: episodes LEFT JOIN state on (podcast_id, guid)
    public func fetchListItems(podcastID: Int64) async throws -> [EpisodeListItem]
    public func observeListItems(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>
}
```

The join uses a `SQLRequest` returning a flat row that you split into
`PodcastEpisode` + optional `PodcastEpisodeState`, or two fetches assembled in
Swift. Prefer one SQL query for `observeListItems` so the observation tracks both
tables. Example shape:

```sql
SELECT e.*,
       s.play_position  AS st_play_position,
       s.play_state     AS st_play_state,
       s.last_played_at AS st_last_played_at,
       s.completed_at   AS st_completed_at,
       s.download_state AS st_download_state,
       s.download_path  AS st_download_path,
       s.download_bytes AS st_download_bytes
FROM podcast_episodes e
LEFT JOIN podcast_episode_state s
    ON s.podcast_id = e.podcast_id AND s.guid = e.guid
WHERE e.podcast_id = ?
ORDER BY e.published_at DESC
```

Decode with a small `FetchableRecord` row struct that carries the `st_*` columns
as optionals and maps to `EpisodeListItem`.

### `EpisodeStateRepository`

This is the **only** writer of user state. Every write upserts the
`(podcast_id, guid)` row, creating it on first touch.

```swift
public struct EpisodeStateRepository: Sendable {
    public init(database: Database)

    public func fetch(podcastID: Int64, guid: String) async throws -> PodcastEpisodeState?

    /// Upsert position and flip play_state to inProgress (unless already played),
    /// stamp last_played_at. Called frequently by the player.
    public func savePosition(podcastID: Int64, guid: String, position: Double, now: Double) async throws

    public func markPlayed(podcastID: Int64, guid: String, now: Double) async throws       // play_state=played, completed_at=now, play_position=0
    public func markUnplayed(podcastID: Int64, guid: String) async throws                  // play_state=unplayed, play_position=0, completed_at=NULL

    public func setDownloadState(podcastID: Int64, guid: String,
                                 state: EpisodeDownloadState, path: String?, bytes: Int64?) async throws

    /// All state rows for a podcast (used by the joined read model / observation).
    public func fetchAll(podcastID: Int64) async throws -> [PodcastEpisodeState]
    public func observe(podcastID: Int64) async -> AsyncThrowingStream<[PodcastEpisodeState], Error>
}
```

Implement the upserts with GRDB's `upsert` on the `PodcastEpisodeState` record,
or an `INSERT … ON CONFLICT(podcast_id, guid) DO UPDATE …`. For `savePosition`,
do **not** overwrite `play_state` when it is already `played` (a finished episode
the user scrubbed back into should keep its state unless they explicitly mark it
unplayed; treat "near the end" specially only in the player, not here).

## Context7 lookups

- `groue/GRDB.swift`: `upsert` / `onConflict` clauses on `PersistableRecord`,
  composite primary keys, `ValueObservation.tracking` across a join, decoding a
  `SQLRequest` into a custom `FetchableRecord` with column-aliased optionals.

## Dependencies

None new. GRDB is already a Persistence dependency.

## Test plan

`Modules/Persistence/Tests/PersistenceTests/` (Swift Testing, in-memory
`Database(location: .inMemory)`):

- **Migration**: a fresh in-memory database migrates clean; the three tables and
  their indexes exist; `podcasts.feed_url` is unique; the FKs cascade
  (deleting a podcast removes its episodes and state rows).
- **PodcastRepository**: insert/fetch round-trips; `upsertByFeedURL` inserts when
  new and, when the feed already exists, updates feed fields while preserving
  `id`, `added_at`, `subscribed`, `auto_download`, `sort_index`;
  `fetchAllSubscribed` ordering; `fetchStale` includes NULL `last_refreshed_at`
  and excludes fresh rows; `observeSubscribed` emits an initial value then again
  on insert.
- **EpisodeRepository**: `upsert` keyed on `(podcast_id, guid)` updates content
  not state; `upsertAll` is one transaction; `pruneEpisodes` removes only
  out-of-set content rows and **leaves state rows intact**; `fetchListItems`
  LEFT JOINs so an episode with no state row yields `state == nil`;
  `observeListItems` emits on both an episode change and a state change.
- **EpisodeStateRepository**: `savePosition` creates the row on first call and
  flips to `inProgress`; a second `savePosition` after `markPlayed` does not
  clobber `played`; `markPlayed`/`markUnplayed` set the expected fields;
  `setDownloadState` round-trips.
- **The critical regression test** (the user's headline requirement): write a
  position via `savePosition`, then run an `EpisodeRepository.upsert` that
  re-inserts the same `(podcast_id, guid)` episode (simulating a feed refresh),
  then assert the state row's `play_position` is unchanged. Begin this slice by
  writing that test and watching it pass once the separate-table design is in.

## Acceptance criteria

- [ ] `M023_Podcasts` migration creates `podcasts`, `podcast_episodes`,
      `podcast_episode_state` with the indexes and FKs from the overview, and is
      registered last in `Migrator.make()`.
- [ ] `Podcast`, `PodcastEpisode`, `PodcastEpisodeState` records round-trip
      through GRDB with correct snake_case column mapping.
- [ ] `EpisodeListItem` + the two state enums exist and are `Sendable`.
- [ ] `PodcastRepository`, `EpisodeRepository`, `EpisodeStateRepository` expose
      the methods above; observations emit initial + change.
- [ ] A feed-refresh upsert of an episode does not reset that episode's saved
      `play_position` (separate-table design verified by test).
- [ ] `make test-persistence` is green; module coverage stays at or above its
      floor.
- [ ] No SwiftLint / SwiftFormat warnings introduced.

## Gotchas

- **Composite-PK record.** `PodcastEpisodeState` has no rowid `id`; conform to
  `PersistableRecord` (like `Lyrics`), set `databaseTableName`, and rely on the
  composite primary key for `upsert`/`fetchOne(key:)`. `fetchOne(db, key:
  ["podcast_id": pid, "guid": g])` is the keyed lookup form.
- **Observation across a join.** `ValueObservation` tracks the tables your
  request reads. A single SQL query over `podcast_episodes LEFT JOIN
  podcast_episode_state` will re-fire on changes to either table, which is what
  the live progress indicators need. Two separate observations zipped together
  is more fragile; prefer the joined query.
- **`requiresWriteAccess` on observations.** The `Database.observe` helper
  already sets `observation.requiresWriteAccess = true` to dodge the WAL-snapshot
  deadlock; do not add a second observation path that bypasses it.
- **Booleans and enums as text.** SQLite stores `Bool` as `INTEGER`; GRDB maps it
  for you. `play_state` / `download_state` are `TEXT`; store the enum
  `rawValue`. Default the missing-state read to `.unplayed` / `.none` in the
  read-model assembly, not in SQL.
- **Do not add FTS triggers here.** If episode search is wanted later, it is its
  own migration; keep this one minimal.

## Handoff

Phase 21-2 (the `Podcasts` module) consumes nothing from this slice directly
(it returns value types), but phase 21-4 (`PodcastService`) injects these three
repositories. Phase 21-5 (playback) reads/writes state through
`EpisodeStateRepository` via the App-layer resolver. Phases 21-7 and 21-9 render
`Podcast` and `EpisodeListItem` and subscribe to the observations.
