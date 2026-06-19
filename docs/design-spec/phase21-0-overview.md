# Phase 21: Podcasts - Overview and Cross-Phase Contract

> Prerequisites: Phases 0 to 20 complete. The module DAG, `QueuePlayer` /
> `PlayableSource` plumbing, the `SubsonicStreamResolving` App-injected seam,
> the GRDB `Database` actor + repository pattern, the `LibraryViewModel`
> sidebar/`SidebarDestination` spine, the `Artwork(artPath:)` loader, and the
> `L10n` localization workflow all exist.
>
> Read `docs/design-spec/_standards.md` first, then this file. **This file is
> the contract.** Phases 21-1 through 21-10 each implement one slice of it; read
> this overview before starting any of them so the shared types, table shapes,
> and protocol seams line up.

## How Phase 21 is split

Podcasts is large, so it is broken into ten implementable slices plus this
overview. Each slice file is self-contained enough to hand to a single session,
but they share the types and contracts defined here. Build them in order; the
"Depends on" line at the top of each file names its hard prerequisites.

| File | Slice | Module(s) touched |
|------|-------|-------------------|
| `phase21-0-overview.md` | This contract (read first) | - |
| `phase21-1-persistence.md` | Schema, records, repositories | Persistence |
| `phase21-2-feeds.md` | `Podcasts` module scaffold, feed fetch + RSS/Atom parse | Podcasts |
| `phase21-3-search.md` | Podcast Index + iTunes dual search, dedupe/merge | Podcasts |
| `phase21-4-subscriptions.md` | `PodcastService` facade: subscribe/refresh/state, artwork cache | Podcasts |
| `phase21-5-playback.md` | `PlayableSource.podcast`, resolver seam, resume + position write-back | Playback, App |
| `phase21-6-downloads.md` | Episode downloads + offline (optional, post-MVP) | Podcasts, App |
| `phase21-7-ui-podcasts-home.md` | Sidebar item, subscribed grid, add bar, UI seam protocols | UI, App |
| `phase21-8-ui-search-detail.md` | Search results list (source badges), detail + Subscribe | UI |
| `phase21-9-ui-episodes.md` | Episode table (date/duration/progress), show notes, context menu | UI |
| `phase21-10-nowplaying-polish.md` | Now Playing podcast mode, speed/skip, settings, docs, l10n sweep | UI, App |

The MVP is phases 21-1, 21-2, 21-3, 21-4, 21-5, 21-7, 21-8, 21-9. Phase 21-6
(downloads) and the speed/settings/polish in 21-10 are enhancements that make
the feature "full featured" but can land after a streaming-only first cut.

## The user's brief, reviewed

The user wants podcasts that feel native to Bòcan, not a bolted-on second app.
Concretely:

1. A **Podcasts** item under **Local Library** in the sidebar.
2. A persistent **Add** affordance at the top of the Podcasts window: add a feed
   by address, or search.
3. Search hits **Podcast Index and the Apple iTunes search index at the same
   time**, combines and deduplicates results, prefers the richer Podcast Index
   data for display, and shows a small badge for where each result came from.
4. Clicking a result drills into full detail from the source, with a Subscribe
   and a Back affordance.
5. Subscribed podcasts render like the album grid: artwork + name + author.
   **Both RSS and Atom feeds** are supported.
6. Clicking a podcast shows its episodes.
7. Episode list: like the track list plus extra columns: date, duration, and a
   progress indicator (unplayed dot / progress bar / played checkmark), lifted
   from Apple Podcasts.
8. Now Playing reuses the music chrome: show artwork in the album-art slot, show
   name in the artist slot, episode title in the track-title slot.
9. **Per-episode playback position is persisted** and written back on pause and
   on app close. This is non-negotiable and is the thing that separates good
   podcast apps from bad ones.

Deliberate refinements (drop any one without unravelling the rest):

- **Podcasts is its own SPM module** (`Modules/Podcasts`), peer to `Subsonic` in
  the DAG. It owns feed fetching, RSS/Atom parsing, dual-index search, the
  subscription + episode + playback-state store access, and artwork caching.
- **Per-episode playback state lives in a separate table** from episode content
  (`podcast_episode_state`, keyed by stable `(podcast_id, guid)`), not as columns
  on the episode row. Feed refresh replaces content freely; user state is
  precious and is never clobbered by a refresh. See "Data model" below.
- **Playback reuses the existing `QueuePlayer` / `AudioEngine` pipeline** via a
  new `PlayableSource.podcast` case and an App-injected `PodcastEpisodeResolving`
  seam, exactly mirroring how Subsonic plugs in through `SubsonicStreamResolving`.
  Podcasts never imports Playback; Playback never imports Podcasts.
- **Podcasts do not scrobble to Last.fm / ListenBrainz.** They are not music
  tracks. The `.podcast` source short-circuits the scrobble path the same way
  `.internetRadio` does.
- **The local "Podcasts" library is distinct from the existing Subsonic server
  Podcasts row** (`SidebarDestination.subsonicPodcasts`). They coexist. This
  phase is the local, feed-based library.
- **Downloads are a first-class but optional enhancement.** Streaming (play the
  enclosure URL straight through `FFmpegDecoder`, seek via HTTP range) is the
  MVP. Downloading for offline + bulletproof seeking is phase 21-6.

## Non-goals

- A podcast hosting / publishing tool. Read + play only.
- Syncing podcast subscriptions into iCloud or across devices.
- OPML import/export (a natural follow-up; out of scope here).
- Video podcasts. Audio enclosures only; ignore video enclosures or show them
  greyed-out as "not supported".
- Chapters UI and transcript display. We persist `chapters_url` /
  `transcript_url` so a future phase can add them, but rendering them is out of
  scope.
- Re-implementing an RSS parser by hand. Wrap FeedKit (see phase 21-2).

## Module placement in the DAG

Add one module. It sits at the same tier as `Subsonic`:

```
Podcasts depends on: Observability, Persistence
UI       gains a dependency on: Podcasts
App      wires the PodcastEpisodeResolving seam and the UI data-source seams
```

Update the dependency table in `_standards.md` (the "Current internal-module
dependencies" table) as part of phase 21-2:

| Module    | Depends on                                                                                            |
|-----------|-------------------------------------------------------------------------------------------------------|
| Podcasts  | Observability, Persistence                                                                            |
| UI        | Observability, Persistence, AudioEngine, Library, Playback, Scrobble, Subsonic, Acoustics, **Podcasts** |

`Podcasts` must **not** import `Playback`, `Subsonic`, `UI`, or `AudioEngine`.
The playback bridge is a protocol (`PodcastEpisodeResolving`) declared in
`Playback` and implemented in `App` over `PodcastService`. The UI bridge is a
set of protocols declared in `UI` (see phase 21-7) and implemented in `App`.

## Data model (the spine)

Three tables, added in one migration (phase 21-1). The next free migration
number at time of writing is **M023** (highest registered is `M022`; verify the
top of `Modules/Persistence/Sources/Persistence/Migrations/Migrator.swift` and
use the next integer). File: `M023_Podcasts.swift`.

### Why state is a separate table

A feed refresh re-fetches the channel and its items. Episodes get added, edited,
and (for shows that only publish the last N items) drop out of the feed and
sometimes reappear. If playback position lived on the episode row, a refresh
that re-inserts an episode would reset the user's position. By keying user state
to the stable `(podcast_id, guid)` identity in its own table, content is freely
replaceable while state is durable and is written only by the player. The two
are joined at read time (LEFT JOIN, so an episode with no state row reads as
unplayed at position 0). This is the design point the user singled out; do not
collapse it back into the episode row.

### `podcasts` (subscriptions)

```sql
CREATE TABLE podcasts (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    feed_url              TEXT NOT NULL,              -- canonical, see "Feed URL canonicalization"
    title                 TEXT NOT NULL,
    author                TEXT,
    description           TEXT,
    artwork_url           TEXT,                       -- remote, from the feed/index
    artwork_path          TEXT,                       -- local cached file (see PodcastArtworkCache)
    link                  TEXT,                       -- show website
    language              TEXT,
    explicit              INTEGER NOT NULL DEFAULT 0,
    categories_json       BLOB,                       -- JSON array of category strings
    owner_name            TEXT,
    owner_email           TEXT,
    copyright             TEXT,
    funding_url           TEXT,                       -- podcast:funding
    itunes_collection_id  INTEGER,                    -- Apple collectionId, when known
    podcast_index_id      INTEGER,                    -- Podcast Index feedId, when known
    http_etag             TEXT,                       -- conditional GET cache validator
    http_last_modified    TEXT,                       -- conditional GET cache validator
    last_refreshed_at     REAL,
    last_refresh_error    TEXT,
    subscribed            INTEGER NOT NULL DEFAULT 1,
    auto_download         INTEGER NOT NULL DEFAULT 0,
    sort_index            INTEGER NOT NULL DEFAULT 0,
    added_at              REAL NOT NULL
);

CREATE UNIQUE INDEX podcasts_feed_url_idx ON podcasts(feed_url);
```

### `podcast_episodes` (content; refreshable)

```sql
CREATE TABLE podcast_episodes (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    podcast_id        INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
    guid              TEXT NOT NULL,                  -- feed item guid, or enclosure URL when absent
    title             TEXT NOT NULL,
    subtitle          TEXT,
    description_html  TEXT,                           -- show notes (raw HTML from the feed)
    audio_url         TEXT NOT NULL,                  -- enclosure URL
    audio_mime        TEXT,                           -- enclosure type, e.g. audio/mpeg
    audio_byte_length INTEGER,                        -- enclosure length attr, when present
    duration          REAL,                           -- seconds; 0/NULL when the feed omits it
    published_at      REAL,                           -- pubDate / atom:updated, epoch seconds
    season            INTEGER,                        -- itunes:season
    episode_number    INTEGER,                        -- itunes:episode
    episode_type      TEXT,                           -- 'full' | 'trailer' | 'bonus'
    artwork_url       TEXT,                           -- episode-level art, when different
    artwork_path      TEXT,
    chapters_url      TEXT,                           -- podcast:chapters (persisted, not rendered)
    transcript_url    TEXT,                           -- podcast:transcript (persisted, not rendered)
    link              TEXT,
    explicit          INTEGER NOT NULL DEFAULT 0,
    added_at          REAL NOT NULL
);

CREATE UNIQUE INDEX podcast_episodes_guid_idx ON podcast_episodes(podcast_id, guid);
CREATE INDEX podcast_episodes_published_idx ON podcast_episodes(podcast_id, published_at DESC);
```

### `podcast_episode_state` (user state; precious)

```sql
CREATE TABLE podcast_episode_state (
    podcast_id     INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
    guid           TEXT NOT NULL,
    play_position  REAL NOT NULL DEFAULT 0,           -- resume point, seconds
    play_state     TEXT NOT NULL DEFAULT 'unplayed',  -- 'unplayed' | 'inProgress' | 'played'
    last_played_at REAL,
    completed_at   REAL,
    download_state TEXT NOT NULL DEFAULT 'none',      -- 'none'|'queued'|'downloading'|'downloaded'|'failed'
    download_path  TEXT,
    download_bytes INTEGER,
    PRIMARY KEY (podcast_id, guid)
);
```

A state row is created lazily (on first play, first position write, or first
download). Absence of a row means unplayed, position 0, not downloaded.

## Shared value types (referenced across phases)

These are the boundary types. Their canonical home is noted; other phases
consume them as named here.

```swift
// Persistence module (phase 21-1). The read model the UI renders: an episode
// joined with its state, so a single fetch carries content + progress.
public struct EpisodeListItem: Sendable, Hashable, Identifiable {
    public var episode: PodcastEpisode          // content row
    public var state: PodcastEpisodeState?       // nil => unplayed, position 0
    public var id: Int64 { self.episode.id ?? 0 }
}

public enum EpisodePlayState: String, Sendable, Codable {
    case unplayed, inProgress, played
}

public enum EpisodeDownloadState: String, Sendable, Codable {
    case none, queued, downloading, downloaded, failed
}
```

```swift
// Podcasts module (phase 21-2). The normalized output of feed parsing, source
// agnostic across RSS and Atom.
public struct ParsedFeed: Sendable {
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: URL?
    public var link: URL?
    public var language: String?
    public var explicit: Bool
    public var categories: [String]
    public var ownerName: String?
    public var ownerEmail: String?
    public var copyright: String?
    public var fundingURL: URL?
    public var episodes: [ParsedEpisode]
}

public struct ParsedEpisode: Sendable {
    public var guid: String
    public var title: String
    public var subtitle: String?
    public var descriptionHTML: String?
    public var audioURL: URL
    public var audioMIME: String?
    public var audioByteLength: Int64?
    public var duration: TimeInterval?
    public var publishedAt: Date?
    public var season: Int?
    public var episodeNumber: Int?
    public var episodeType: String?            // "full" | "trailer" | "bonus"
    public var artworkURL: URL?
    public var chaptersURL: URL?
    public var transcriptURL: URL?
    public var link: URL?
    public var explicit: Bool
}
```

```swift
// Podcasts module (phase 21-3). One deduplicated, merged search hit.
public struct PodcastSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { self.canonicalFeedKey }   // dedupe key, see below
    public var feedURL: URL
    public var canonicalFeedKey: String
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var description: String?
    public var episodeCount: Int?
    public var lastPublishedAt: Date?
    public var categories: [String]
    public var sources: Set<PodcastSearchSource>       // may contain both
    public var podcastIndexID: Int?
    public var itunesCollectionID: Int?
}

public enum PodcastSearchSource: String, Sendable, Codable, CaseIterable {
    case podcastIndex
    case itunes
}
```

```swift
// Playback module (phase 21-5). The App-injected seam, mirroring
// SubsonicStreamResolving. Playback calls these; the App implements them over
// PodcastService. Playback never imports Podcasts.
public protocol PodcastEpisodeResolving: Sendable {
    /// Local downloaded file URL when present, else the remote enclosure URL.
    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL
    /// Seconds to resume from. Return 0 when there is no saved position or the
    /// episode is effectively complete.
    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval
    /// Persist the current position. Called on a timer while playing and on
    /// pause / stop / app-quit.
    func persistPosition(feedURL: URL, episodeGUID: String, position: TimeInterval, duration: TimeInterval) async
    /// Mark the episode fully played and reset its resume position.
    func markPlayed(feedURL: URL, episodeGUID: String) async
}
```

## Feed URL canonicalization (shared contract)

Used in two places that must agree: the search dedupe key (phase 21-3) and the
`podcasts.feed_url` uniqueness + subscribe lookup (phase 21-4). Implement once in
the `Podcasts` module as `FeedURL.canonicalKey(_:)` and reuse.

Rules for the **dedupe/identity key** (a `String`, not a `URL`):

1. Lowercase the scheme and host.
2. Treat `http` and `https` as equivalent: drop the scheme from the key entirely.
3. Drop a default port (`:80`, `:443`).
4. Drop a trailing `/` on the path.
5. Drop the URL fragment.
6. Keep the path (case-sensitive) and the query string verbatim (some feeds
   require query parameters; do not strip them).
7. Drop a leading `www.` on the host.

So `https://www.Example.com:443/feed/?x=1#top` and `http://example.com/feed?x=1`
produce the same key `example.com/feed?x=1`.

When **storing** a subscription, keep the original absolute URL (prefer the
`https` variant when both were seen), but enforce uniqueness on the canonical
key by also storing it or by canonicalizing before the unique-index lookup. The
simplest correct approach: store the normalized absolute URL (https-preferred,
no trailing slash, no fragment) in `feed_url`, and compute the dedupe key from it
on the fly.

## End-to-end walkthrough (how the pieces meet)

1. User selects **Podcasts** in the sidebar (`SidebarDestination.podcasts`).
   `ContentPane` shows `PodcastsHomeView`: an Add bar on top, a grid of
   subscribed shows below (phase 21-7).
2. User types in the Add bar. `PodcastSearchService` fans out to Podcast Index
   and iTunes concurrently, merges + dedupes, returns `[PodcastSearchResult]`.
   The results list shows artwork, title, author, and a source badge (phase
   21-8). If the text is a feed URL, an "Add this feed" affordance appears.
3. User clicks a result. The detail view fetches and parses the feed
   (`FeedFetcher` + `FeedParser`), shows channel metadata + a preview of recent
   episodes, and a **Subscribe** button (phase 21-8).
4. Subscribe calls `PodcastService.subscribe(feedURL:)`: parse, upsert the
   `podcasts` row, upsert `podcast_episodes`, cache artwork to a local path
   (phase 21-4). The grid now shows the new show.
5. User clicks the show (`SidebarDestination.podcastShow(id)`). The episode
   table renders `[EpisodeListItem]` with date, duration, and a progress
   indicator derived from `state` (phase 21-9).
6. User plays an episode. The UI builds a podcast `QueueItem`
   (`PlayableSource.podcast(feedURL:episodeGUID:)`, title = episode, artistName =
   show) and hands it to `QueuePlayer`. On load, the player asks the resolver for
   `audioURL` and `resumePosition`, seeks to the resume point, and plays (phase
   21-5).
7. While playing, the player calls `persistPosition` on a ~5 s cadence and on
   pause/stop/quit. When the episode completes it calls `markPlayed`. The episode
   table's progress indicator updates live via the state `ValueObservation`
   (phases 21-5, 21-9).
8. Now Playing shows the episode in podcast mode: show art, episode title, show
   name; skip-back/skip-forward and a speed control (phase 21-10).

## Build, test, and wiring checklist (applies to every phase)

- After editing `Modules/Podcasts/Package.swift`, the UI/`Podcasts` manifests,
  or `project.yml`, run `make generate` so `Bocan.xcodeproj` picks up the change.
- Add a `make test-podcasts` target to the root `Makefile` mirroring the other
  per-module SPM test targets, and a per-module coverage floor entry in the
  `coverage-all` machinery. Do this in phase 21-2 when the module first exists.
- Per the standards: 80% line coverage per module, Swift Testing
  (`import Testing`), no network in tests (stub via `URLProtocol` or a
  protocol-based HTTP client mock), fixtures checked in under
  `Modules/Podcasts/Tests/PodcastsTests/Fixtures/`.
- Run `make format && make lint && make build && make test-<module>` before each
  commit. Conventional Commits, scope = module: `feat(podcasts): …`,
  `feat(playback): …`, `feat(ui): …`, `feat(persistence): …`.

## Localization note (carry into every UI phase)

All UI chrome (labels, buttons, column headers, menu items, accessibility
labels, toasts, errors) routes through `L10n` in the `UI` module catalog, and
`make pseudolocale` runs after adding keys (see `docs/design-spec/localization.md`
and the `UI` module CLAUDE.md). **Podcast titles, episode titles, author names,
and show notes are user content, not chrome** - they come from the feed and are
rendered verbatim, exactly like track titles. Do not attempt to localize feed
content; do localize every surrounding label.

## Glossary

- **Feed**: an RSS 2.0 or Atom XML document at a URL describing a podcast.
- **Channel / Show / Podcast**: the feed-level entity. A `podcasts` row.
- **Episode / Item**: one entry in the feed. A `podcast_episodes` row.
- **Enclosure**: the audio file URL attached to an episode.
- **GUID**: the feed item's stable identifier; the join key for state.
- **Subscription**: a `podcasts` row with `subscribed = 1`.
- **Podcast Index**: <https://podcastindex.org>, an open podcast directory with a
  keyed JSON API.
- **iTunes Search**: Apple's keyless podcast search/lookup JSON API at
  `itunes.apple.com`.

## Handoff

When all of Phase 21 lands:

- `PlayableSource` gains `.podcast`; it is the source of truth for "this queue
  item is a podcast episode", and the resume/position/markPlayed behaviour hangs
  off the `PodcastEpisodeResolving` seam.
- The `Podcasts` module is the home for any future feed-based source work (OPML
  import, chapters, transcripts, cross-device sync).
- The episode-state table is the durable home for per-episode progress; future
  work (a unified "continue listening" rail, Up Next podcast smart rules) reads
  from it.
