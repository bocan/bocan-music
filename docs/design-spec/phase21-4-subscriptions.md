# Phase 21-4: Podcasts - PodcastService facade (subscribe, refresh, state, artwork)

> Depends on: `phase21-0-overview.md`, `phase21-1-persistence.md` (records +
> repositories), `phase21-2-feeds.md` (`FeedFetcher`, `FeedParser`,
> `FeedURL`, `PodcastsError`). Phase 21-3 is optional here (only the subscribe
> path can opportunistically carry index IDs).
>
> Provides: `PodcastService` - the single public facade the App layer wires into
> both the UI data-source seams (21-7) and the playback resolver seam (21-5);
> plus `PodcastArtworkCache` and the refresh scheduler.

## Goal

Tie feeds + persistence together. `PodcastService` is the actor that subscribes
to a feed, refreshes feeds (without clobbering user state), exposes episodes,
caches artwork to local files, and reads/writes per-episode playback state. It is
the seam the rest of the app talks to for everything podcast-data-related.

## Non-goals

- No UI (phases 21-7 to 21-10).
- No `PlayableSource` / `QueuePlayer` changes (phase 21-5). This slice only
  exposes the state read/write methods the resolver will call.
- No downloads (phase 21-6). `PodcastArtworkCache` here is only for cover art.

## Outcome shape

```
Modules/Podcasts/Sources/Podcasts/
├── PodcastService.swift                 # the actor facade
├── PodcastArtworkCache.swift            # cover art -> local file path
├── FeedRefreshScheduler.swift           # periodic + on-demand refresh
└── Mapping/
    └── ParsedFeed+Records.swift         # ParsedFeed/ParsedEpisode -> Podcast/PodcastEpisode
```

## `PodcastService`

```swift
public actor PodcastService {
    public init(
        podcastRepo: PodcastRepository,
        episodeRepo: EpisodeRepository,
        stateRepo: EpisodeStateRepository,
        fetcher: FeedFetcher = FeedFetcher(),
        parser: FeedParser = FeedParser(),
        artwork: PodcastArtworkCache,
        search: PodcastSearchService? = nil,     // optional; lets subscribe carry index IDs
        now: @escaping @Sendable () -> Date = { Date() },
        log: AppLogger = .make(.network)
    )

    // MARK: Subscriptions
    /// Fetch + parse + persist a podcast and its current episodes; cache artwork.
    /// Idempotent on feed URL (upsert). Returns the podcast row id.
    @discardableResult
    public func subscribe(feedURL: URL, indexHints: PodcastSearchResult? = nil) async throws -> Int64
    public func unsubscribe(podcastID: Int64) async throws            // deletes row (cascades), evicts artwork + downloads
    public func setAutoDownload(_ on: Bool, podcastID: Int64) async throws
    public func reorder(podcastIDs: [Int64]) async throws             // persists sort_index

    // MARK: Refresh
    /// Conditional GET; on 304 just stamp last_refreshed_at; on 200 upsert
    /// episodes (content only) and cache new artwork. Never touches state rows.
    public func refresh(podcastID: Int64) async throws -> RefreshOutcome
    public func refreshAllStale(olderThan: TimeInterval = 3600) async      // best-effort, logs per-feed errors

    // MARK: Reads (feed the UI data-source seam in 21-7)
    public func subscribedPodcasts() async throws -> [Podcast]
    public func episodes(podcastID: Int64) async throws -> [EpisodeListItem]
    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
    public func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>

    // MARK: Playback-state bridge (the resolver in 21-5 calls these)
    /// Resolve the enclosure (or, later, a downloaded file) for an episode by feed+guid.
    public func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL
    public func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval
    public func saveProgress(feedURL: URL, episodeGUID: String, position: TimeInterval, duration: TimeInterval) async
    public func markPlayed(feedURL: URL, episodeGUID: String) async
    public func markUnplayed(feedURL: URL, episodeGUID: String) async
}

public struct RefreshOutcome: Sendable {
    public var notModified: Bool
    public var newEpisodeCount: Int
    public var totalEpisodeCount: Int
}
```

### `subscribe`

1. `let stored = FeedURL.normalizedStorageURL(feedURL)` (reject non-http(s) with
   `PodcastsError.invalidFeedURL`).
2. `fetcher.fetch(stored, etag: nil, lastModified: nil)` then `parser.parse`.
3. Map `ParsedFeed` to a `Podcast` (carry `indexHints?.podcastIndexID` /
   `itunesCollectionID` when present, `subscribed = true`, `added_at = now`,
   `http_etag`/`http_last_modified` from the fetch result). `upsertByFeedURL`.
4. Map each `ParsedEpisode` to a `PodcastEpisode` (`podcast_id` from step 3) and
   `episodeRepo.upsertAll`.
5. Kick `artwork.cache(podcastID:, url:)` for the show art (and episode art when
   present) as a detached, non-blocking task; the subscribe call returns without
   waiting on artwork (the UI shows a placeholder then the cached file).
6. Return the podcast id.

`subscribe` is idempotent: subscribing to an already-subscribed feed refreshes it
and flips `subscribed = 1` (covers the "re-subscribe after unsubscribe" case).

### `refresh`

1. Load the `Podcast`; pass its `http_etag` / `http_last_modified` to
   `fetcher.fetch`.
2. On `notModified`: stamp `last_refreshed_at = now`, clear `last_refresh_error`,
   return `RefreshOutcome(notModified: true, …)`.
3. On 200: parse, `upsertByFeedURL` (updates channel fields + new validators),
   diff the parsed guids against existing to count new episodes,
   `episodeRepo.upsertAll`, cache any new artwork, stamp success, return the
   outcome.
4. On error: store a short message in `last_refresh_error`, stamp
   `last_refreshed_at`, log a warning, **rethrow** so a user-initiated refresh
   can surface a toast. `refreshAllStale` catches per-feed so one bad feed does
   not stop the batch.
5. **Never** call any `EpisodeStateRepository` write during refresh. Optionally
   prune very old content rows (`episodeRepo.pruneEpisodes(keepGUIDs:)`) only when
   a show publishes a rolling window; default to **no pruning** in MVP so the
   user's history of played episodes never disappears. If pruning is added, keep
   any episode that has a non-default state row (played / in-progress / downloaded)
   regardless of whether it is still in the feed.

### Playback-state bridge

These four/five methods are what the App-layer `PodcastEpisodeResolving`
implementation (21-5) forwards to. They translate `feedURL + guid` into
`(podcastID, guid)`:

- Resolve `podcastID` via `podcastRepo.fetchByFeedURL(FeedURL.normalizedStorageURL)`;
  cache the `feedURL -> podcastID` mapping in-actor to avoid a DB hit on every
  5-second position write.
- `audioURL`: look up the episode (`episodeRepo.fetchByGUID`); if a download
  exists (`state.downloadState == .downloaded`, `download_path` present and the
  file exists) return the file URL, else return the episode's `audio_url`. (In
  MVP without downloads, always the enclosure URL.)
- `resumePosition`: read state; return `play_position` unless the episode is
  effectively complete. "Effectively complete": `play_state == .played`, or
  `duration > 0 && position >= duration - 15`. In those cases return 0 (start
  over) so a finished episode replays from the top.
- `saveProgress`: `stateRepo.savePosition(...)`. Additionally, if
  `duration > 0 && position >= duration - 15`, call `markPlayed` instead (the
  player also calls `markPlayed` on natural end; this covers a user who scrubs to
  the end). Ignore `position <= 0`.
- `markPlayed` / `markUnplayed`: forward to the state repo.

## `PodcastArtworkCache`

Self-contained (the module depends only on Observability + Persistence; do not
reach into `Library`'s cache). Cache cover art to a stable local path so the
existing UI `Artwork(artPath:)` loader can render it directly.

```swift
public actor PodcastArtworkCache {
    public init(http: any HTTPClient = URLSession.shared, root: URL? = nil)

    /// Download `url` (if not already cached) to a file under the cache root and
    /// write its path into podcasts.artwork_path via the repo. Best-effort; logs
    /// and returns nil on failure (the UI falls back to a gradient placeholder).
    @discardableResult
    public func cachePodcastArt(podcastID: Int64, url: URL?, repo: PodcastRepository) async -> String?

    @discardableResult
    public func cacheEpisodeArt(episodeID: Int64, podcastID: Int64, url: URL?, repo: EpisodeRepository) async -> String?

    public func evict(podcastID: Int64) async      // remove the show's art directory
}
```

- Root: `~/Library/Caches/io.cloudcauldron.bocan/Podcasts/Artwork/<podcastID>/`.
  File name derived from a hash of the URL + the URL's extension; default `.jpg`.
- Downsample is not needed here (the UI `ArtworkLoader` downsamples at decode);
  store the original bytes.
- 10 s timeout, size cap (e.g. 5 MB) to defend against a hostile image URL.
- Eviction on unsubscribe removes the directory.

## `FeedRefreshScheduler`

```swift
public actor FeedRefreshScheduler {
    public init(service: PodcastService, interval: TimeInterval = 1800)
    public func start() async      // loop: refreshAllStale(); sleep(interval); honour cancellation
    public func stop() async
    public func refreshNow() async // user-initiated "refresh all"
}
```

- Default interval 30 minutes; the actual per-feed gate is `refreshAllStale`'s
  `olderThan` so a manual refresh does not double-fetch fresh feeds.
- The App layer starts it after launch and on
  `NSWorkspace.didWakeNotification` (a future nicety; at minimum start once on
  launch). Respect `Task.checkCancellation()`; stop on app teardown.
- Keep it modest: refresh is best-effort and must never block the UI or churn the
  network on a tight loop.

## Context7 lookups

With Context7 lookups, ALWAYS choose the latest version of a dependency (FeedKit, GRDB, etc.) and avoid any deprecated APIs. Where the spec deviates from this, stop and ask for clarification before proceeding.

- Apple `URLSession` download-to-file (`URLSessionDownloadTask`) vs `data(for:)`
  for the artwork cache (a plain `data(for:)` + write is fine here; downloads
  proper are phase 21-6).
- `groue/GRDB.swift`: batched upsert in a single `write` transaction for
  `upsertAll`.

## Dependencies

None new (FeedKit + Persistence + Observability already present).

## Test plan

No network: inject `HTTPClient` mocks into `FeedFetcher` and
`PodcastArtworkCache`; use an in-memory `Database` for the repos.

- **subscribe**: parses a fixture feed, writes one `podcasts` row and N
  `podcast_episodes` rows; re-subscribing the same feed upserts (no duplicate
  rows) and re-flags `subscribed`; index hints land in `itunes_collection_id` /
  `podcast_index_id`.
- **refresh - 304**: a feed returning 304 stamps `last_refreshed_at`, leaves
  episodes untouched, returns `notModified: true`.
- **refresh - new episode**: a feed with one extra item upserts only the new row;
  `newEpisodeCount == 1`.
- **refresh preserves state (headline)**: save a position on an episode, then
  refresh a feed that re-lists that episode (and edits its title); assert the
  state row's `play_position` is unchanged and the title updated.
- **resumePosition**: returns the saved position; returns 0 when `play_state ==
  played`; returns 0 when within 15 s of the end.
- **saveProgress near end** auto-marks played.
- **audioURL**: returns the enclosure URL when no download; returns the file URL
  when a `.downloaded` state row with an existing file is present (use a temp
  file).
- **unsubscribe**: removes the podcast (and via cascade its episodes + state) and
  evicts artwork.
- **artwork cache**: writes a file and the path into the row; a second call for
  the same URL does not re-download (assert the mock saw one request).

## Acceptance criteria

- [ ] `PodcastService.subscribe` is idempotent on feed URL and persists channel +
      episodes + artwork; `unsubscribe` cascades and evicts.
- [ ] `refresh` does conditional GET, upserts content, and **never** writes a
      state row; `refreshAllStale` is per-feed fault-tolerant.
- [ ] The state bridge (`resumePosition` / `saveProgress` / `markPlayed`) behaves
      per the completion rules; the `feedURL -> podcastID` lookup is cached.
- [ ] `PodcastArtworkCache` caches once and writes a usable local path.
- [ ] `FeedRefreshScheduler` refreshes on an interval, honours cancellation, and
      does not hot-loop.
- [ ] `make test-podcasts` green; coverage at or above floor.
- [ ] No SwiftLint / SwiftFormat warnings.

## Gotchas

- **State writes are the player's job, by way of this service.** Keep refresh and
  state strictly separate inside the actor; a stray `markPlayed` in the refresh
  path silently destroys the feature's whole value. The headline test guards it.
- **`feedURL -> podcastID` on every position write.** Position is written every
  ~5 s; do not hit the DB to resolve the id each time. Cache the mapping in the
  actor and invalidate on unsubscribe.
- **Effective-completion threshold (15 s) is shared** with the player (21-5) and
  the UI progress indicator (21-9). Define it once as a constant in the module
  (`PodcastPlayback.completionTailSeconds`) and reference it everywhere so they
  agree.
- **Artwork is best-effort.** Never let a failed image download fail a subscribe
  or refresh; the UI placeholder covers it.
- **Idempotent re-subscribe.** A user who unsubscribes then re-subscribes must
  get their old state back (it was keyed by `(podcast_id, guid)` and the podcast
  row was deleted on unsubscribe, so state cascaded away). If preserving state
  across unsubscribe matters, soft-delete (`subscribed = 0`) instead of row
  delete on unsubscribe; **decide this explicitly**. Recommendation: unsubscribe
  sets `subscribed = 0` and stops refreshing, but keeps rows (and state) for, say,
  30 days, then a cleanup removes long-unsubscribed shows. Document whichever you
  pick; the simple MVP is a hard delete with the trade-off called out in the UI
  ("Unsubscribe removes downloaded episodes and playback history for this show").
- **Time source injected.** All `now` comes from the injected closure so tests
  are deterministic and the standards' "no `Date()` sprinkled around" intent
  holds.

## Handoff

Phase 21-5's App-layer `PodcastEpisodeResolving` implementation forwards directly
to `audioURL` / `resumePosition` / `saveProgress` / `markPlayed`. Phase 21-7's
App-layer UI data source forwards to `subscribedPodcasts` / `episodes` / the
observations and to `subscribe` / `unsubscribe` / `refresh`. Phase 21-8 calls
`subscribe` from the detail view's Subscribe button.
