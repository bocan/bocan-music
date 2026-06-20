# Phase 21-12-i: podcast:guid identity and de-duplication

> Depends on: `phase21-11-feedkit-upgrade.md` (FeedKit on 10.4.0; the
> `podcast:guid` tag is parsed into `ParsedFeed.podcastGUID` and persisted to the
> `podcasts.podcast_guid` column via M024). Also builds on
> `phase21-12-podcast-features.md` (the contract) and `phase21-0-overview.md`
> (the feed-URL canonicalization contract). Read `_standards.md` first.
>
> Touches **Persistence** and **Podcasts** only. One new migration (a non-unique
> index), one new repository read, and a small change to the subscribe identity
> resolution. No UI, no seam change, no new entitlement.

## Goal

Use `podcast:guid` (the Podcasting 2.0 show identity, parsed and stored in
phase 21-11) to recognize the same show across feed-URL changes (host
migrations, CDN moves) and avoid duplicate subscriptions. When a feed that the
user subscribes to carries a `podcast_guid` that already belongs to a different
`feed_url` in the table, treat it as the same show: update the stored `feed_url`
in place rather than inserting a second row. Honour the same update when a feed
permanently redirects, using the `finalURL` `FeedFetcher` already captures.

## Non-goals

- No cross-device subscription sync (still a Phase 21 non-goal).
- No merging of distinct shows. Two different non-null guids never collapse into
  one row, and a null guid never triggers a merge.
- No UI surface. Identity resolution is silent (see "UX decision" below); if a
  later slice wants a "this feed moved" toast it would add localized chrome then.
- No change to `EpisodeRepository` / `podcast_episodes` identity. Episode state
  stays keyed on `(podcast_id, guid)` exactly as today; only the show row's
  `feed_url` can change, and `podcast_id` is preserved, so state survives.

## Outcome shape (file tree)

```
Modules/Persistence/Sources/Persistence/
  Migrations/
    M026_PodcastGUIDIndex.swift          (new: non-unique index on podcasts(podcast_guid))
    Migrator.swift                       (edit: register M026 after M025)
  Repositories/
    PodcastRepository.swift              (edit: add fetchByPodcastGUID(_:))

Modules/Persistence/Tests/PersistenceTests/
  MigrationTests.swift                   (edit: bump count + schema version to 26; add index check)
  PodcastRepositoryTests.swift           (edit: fetchByPodcastGUID + URL-rehost upsert cases)

Modules/Podcasts/Sources/Podcasts/
  PodcastService.swift                   (edit: guid-vs-feedURL identity resolution in subscribe)

Modules/Podcasts/Tests/PodcastsTests/
  PodcastServiceTests.swift              (edit: rehost-by-guid, null-guid, distinct-guid, redirect)
```

> Migration numbering: M024 is the highest registered today; sub-phase a
> (`phase21-12-a`) claims **M025** for `funding_text`. Per the 21-12 build order
> a lands before i, so this slice uses **M026**. Confirm the next free integer at
> the top of `Migrator.swift` before writing, and adjust the schema-version /
> count assertions to whatever the actual head is.

## Data model

### M026: non-unique index on `podcasts(podcast_guid)`

A read by guid runs on every subscribe (to find a same-show row under another
URL), so it gets an index. It is **non-unique**: feeds may share a guid (a
network publishing several shows can misconfigure it) or omit it entirely (the
column is `NULL` for every pre-21-11 row until its next refresh), and SQLite
treats every `NULL` as distinct, so a unique index would not even constrain the
nulls usefully. `feed_url` remains the enforced identity (its `UNIQUE` index from
M023 stands); the guid index is a lookup aid, not a constraint. Mirror
`M024_PodcastGUID.swift` and the M023 index idiom (`try db.execute(sql: "CREATE
INDEX ...")`):

`Modules/Persistence/Sources/Persistence/Migrations/M026_PodcastGUIDIndex.swift`

```swift
import GRDB

/// Migration 026: adds a non-unique index on `podcasts(podcast_guid)`.
///
/// Speeds the subscribe-time "is this show already here under a different
/// feed_url?" lookup that backs guid-based de-duplication across feed moves.
/// See `docs/design-spec/phase21-12-i-guid-identity.md`.
///
/// Deliberately NOT unique: feeds may share or omit the guid (the column is
/// NULL for rows last refreshed before the tag was parsed), so `feed_url`
/// remains the enforced identity; this index only accelerates the read.
enum M026PodcastGUIDIndex {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("026_podcast_guid_index") { db in
            try db.execute(sql: "CREATE INDEX podcasts_podcast_guid_idx ON podcasts(podcast_guid)")
        }
    }
}
```

Register it in `Migrator.make()` directly after `M025PodcastFundingText.register(in:&dm)`.

### `PodcastRepository.fetchByPodcastGUID(_:)`

A read mirroring `fetchByFeedURL(_:)`. It must skip the null/empty case at the
call site (passing `nil` is meaningless and `Column("podcast_guid") == nil`
SQL-`NULL` semantics would not behave like a value match), so the method takes a
non-optional `String` and callers guard before calling. Because the index is
non-unique, return the first match ordered deterministically (lowest `id`) so a
pathological shared-guid feed yields a stable, repeatable row rather than an
arbitrary one:

```swift
/// Fetches the lowest-id podcast carrying `podcastGUID`, or nil if none.
///
/// The `podcast_guid` index is non-unique (feeds may share the tag), so this
/// orders by `id` for a deterministic result. Pass a non-empty guid only;
/// callers must not call this for a null/empty guid (feed_url is the identity
/// when the guid is absent).
public func fetchByPodcastGUID(_ podcastGUID: String) async throws -> Podcast? {
    try await self.database.read { db in
        try Podcast
            .filter(Column("podcast_guid") == podcastGUID)
            .order(Column("id"))
            .fetchOne(db)
    }
}
```

## Implementation (subscribe / refresh identity resolution)

All identity work lives in `PodcastService.subscribe(feedURL:indexHints:)`.
`refresh(podcastID:)` already resolves identity by `podcast_id` (the row exists),
so it needs no guid logic; it keeps using `upsertByFeedURL`. The only behavioural
change is at subscribe time, plus capturing the redirect-final URL.

Precedence (state this exactly, it is the heart of the slice):

1. **guid match wins when the parsed guid is non-null** and an existing row under
   a DIFFERENT `feed_url` carries the same guid: this is the same show that
   moved. Update that row's `feed_url` to the new (normalized, post-redirect) URL
   instead of inserting a duplicate.
2. **Otherwise `feed_url` is the identity** (canonical, https-preferred, no
   trailing slash, per `FeedURL.normalizedStorageURL`). This is the existing
   `upsertByFeedURL` path: same URL refreshes content, new URL inserts a row.
3. **Never merge across two distinct guids**, and **never collapse rows when the
   parsed guid is null** (fall straight to step 2).

### Redirect capture

`FeedFetcher.fetch` already returns `FeedFetchResult.finalURL` (the URL after
following redirects). `subscribe` currently fetches the user-supplied `stored`
URL and persists `stored`. Change it to persist the canonicalized `finalURL` when
the server permanently moved the feed, so a moved feed updates its stored URL
even when the guid is absent:

```swift
let fetchResult = try await fetcher.fetch(stored, etag: nil, lastModified: nil)
// The feed may have redirected; store where it actually lives.
let effectiveURL = FeedURL.normalizedStorageURL(fetchResult.finalURL) ?? stored
```

Use `effectiveURL` (not the raw `stored`) as the URL passed to `parsed.toPodcast`
and as the dedupe lookup key below. Parse uses the bytes already fetched, so the
parse `sourceURL` can stay `stored` (it only labels errors) or move to
`effectiveURL`; prefer `effectiveURL` for consistency.

### The resolution block (replaces the single `upsertByFeedURL` call in subscribe)

```swift
let parsed = try parser.parse(data, sourceURL: effectiveURL)

var podcast = parsed.toPodcast(
    feedURL: effectiveURL,
    hints: indexHints,
    etag: fetchResult.etag,
    lastModified: fetchResult.lastModified,
    now: self.now()
)

let podcastID: Int64
// Identity: a non-null guid that already exists under a DIFFERENT feed_url means
// the show moved. Re-point that row's feed_url; do not insert a duplicate.
if let guid = parsed.podcastGUID, !guid.isEmpty,
   let existing = try await podcastRepo.fetchByPodcastGUID(guid),
   existing.feedURL != effectiveURL {
    self.log.info(
        "podcast.subscribe.guidRehost",
        ["id": existing.id ?? -1, "from": existing.feedURL, "to": effectiveURL.absoluteString]
    )
    // Preserve identity/user-owned fields from the existing row; adopt the new
    // URL and reset the conditional-GET validators so the next GET is clean.
    podcast.id = existing.id
    podcast.addedAt = existing.addedAt
    podcast.subscribed = existing.subscribed
    podcast.autoDownload = existing.autoDownload
    podcast.sortIndex = existing.sortIndex
    podcast.httpETag = nil
    podcast.httpLastModified = nil
    try await podcastRepo.update(podcast)        // update by id, moving feed_url
    podcastID = existing.id ?? 0
    // Invalidate any id-cache entry under the old URL key.
    self.idCache.removeValue(forKey: existing.feedURL)
} else {
    // No guid match (or null guid): feed_url is the identity. Existing path.
    podcastID = try await podcastRepo.upsertByFeedURL(podcast)
}
self.idCache[effectiveURL.absoluteString] = podcastID
```

Notes:

- **etag / last-modified reset on URL change.** The old `http_etag` /
  `http_last_modified` validated the *old* URL's bytes; carrying them to a new
  origin risks a spurious 304. Null them on rehost (the contract asks for this);
  the next `refresh` then does one clean GET and re-learns fresh validators.
- **`update` vs `upsertByFeedURL`.** The rehost branch uses `update(_:)` keyed on
  `id` (the row exists; we are changing its `feed_url`). `upsertByFeedURL` keys on
  `feed_url` and would *insert* under the new URL: the duplicate we are avoiding.
- **Episode state survives.** After resolving `podcastID`, the existing
  `episodeRepo.upsertAll(...)` runs against that id. Episodes and
  `podcast_episode_state` are keyed on `(podcast_id, guid)`, and `podcast_id` did
  not change, so resume positions and played flags survive the rehost intact.
- **`feed_url` uniqueness still holds.** A row already at `effectiveURL` would
  have been the guid-match target; the only true edge (two distinct guids at the
  same URL over time) surfaces as a write error, which is correct: we never
  silently merge distinct shows.

### UX decision: auto-update silently vs confirm

**Recommendation: auto-update silently** when the guid matches exactly. By the
Podcasting 2.0 spec `podcast:guid` is a stable show-level identifier intended to
survive feed-URL changes, so an exact match is strong, intentional evidence that
this is the same show the user already follows; re-pointing the existing
subscription is the least-surprising outcome (the alternative, a duplicate row,
is the actual papercut). The event is logged at `info` for traceability. A
confirmation prompt would interrupt a routine, reversible action and would need
localized chrome; it is not warranted. If product later wants a "show moved to
<host>" notice, it belongs as a localized toast in a UI slice off the
`podcast.subscribe.guidRehost` event, not a blocking dialog. Any such prompt MUST
route through `L10n`; this slice adds none.

## Context7 lookups

None needed. This slice uses only GRDB query-builder APIs (`Column`, `filter`,
`order`, `fetchOne`) and patterns already in `PodcastRepository`, plus the
existing `FeedFetcher.finalURL` and `FeedURL.normalizedStorageURL`. The
`podcast:guid` semantics were settled in phase 21-11; no new external API is
introduced. (If anything, re-confirm at implementation that `FeedFetchResult`
still exposes `finalURL` and that `update(_:)` keys on `id` in the resolved GRDB
version, both of which are current in-repo facts, not library lookups.)

## Test plan

Swift Testing, in-memory database, no network (use the existing `HTTPClient`
seam / `URLProtocol` stub the Podcasts tests already use; never hit the wire).
Fixtures checked in under the touched module's `Tests/.../Fixtures/`.

- **`PodcastRepositoryTests` (Persistence):**
  - `fetchByPodcastGUID` returns the matching row, and `nil` when no row carries
    the guid.
  - With two rows sharing a guid (constructed directly), `fetchByPodcastGUID`
    returns the lowest-`id` row deterministically.
  - A direct rehost: insert a row at URL A with guid G; build a podcast for URL B
    with guid G and the existing `id`; `update`; assert one row, `feed_url == B`,
    same `id`, and `addedAt` / `subscribed` / `sort_index` preserved.
- **`PodcastServiceTests` (Podcasts, via the stubbed fetcher):**
  - **Rehost by guid:** subscribe feed at URL A (guid G) -> one row. Subscribe a
    feed served at URL B whose bytes carry the same guid G -> still one row, its
    `feed_url` is now B, `http_etag` / `http_last_modified` are nil, and the row
    `id` is unchanged (no duplicate).
  - **Null guid falls back to feed_url:** subscribe two feeds with `podcast_guid`
    null under URLs A and B -> two distinct rows (no accidental merge).
  - **Distinct guids stay separate:** subscribe feed (guid G1, URL A) and feed
    (guid G2, URL B) -> two rows; neither adopts the other's URL.
  - **Redirect updates the stored URL:** stub the fetcher so a subscribe to URL A
    returns `finalURL` URL B (even with a null guid) -> the stored `feed_url` is
    the canonicalized B.
  - **State survives a rehost:** seed a `podcast_episode_state` row (a resume
    position) under the pre-rehost `podcast_id`; after a guid rehost, the same
    `podcast_id` still owns that state (resume position intact). Guards the "state
    is precious" invariant across a URL change.
- **`MigrationTests` (Persistence):** bump the count assertion and the
  schema-version assertion to the new head (26 if a/M025 has landed), update the
  two test display names that name the count, and add a check that an index named
  `podcasts_podcast_guid_idx` exists after migration (query
  `sqlite_master WHERE type='index'`).

## Acceptance criteria

- [ ] M026 adds a **non-unique** index `podcasts_podcast_guid_idx` on
      `podcasts(podcast_guid)`, registered in `Migrator.make()` after M025;
      `feed_url`'s unique index is untouched.
- [ ] `PodcastRepository.fetchByPodcastGUID(_:)` exists, takes a non-optional
      `String`, and returns the lowest-`id` match (or nil).
- [ ] Subscribe resolves identity by guid first (non-null match under a different
      `feed_url` re-points the existing row via `update`, never inserts a
      duplicate), and by canonical `feed_url` otherwise.
- [ ] On a guid rehost the stored `feed_url` becomes the new (normalized,
      post-redirect) URL and `http_etag` / `http_last_modified` are reset to nil;
      `id`, `addedAt`, `subscribed`, `autoDownload`, `sortIndex`, and the show's
      episode state are preserved.
- [ ] `FeedFetcher.finalURL` is honoured: a permanently redirected feed updates
      its stored URL even when the guid is null.
- [ ] A null guid never merges rows; two distinct guids never merge; identity
      resolution is silent (logged at `info`, no UI).
- [ ] `MigrationTests` count + schema-version assertions reflect the new head and
      an index-existence check passes; new repository and service tests cover
      rehost, null-guid, distinct-guid, redirect, and state-survival, with no
      network.
- [ ] `make format && make lint && make build && make test-persistence &&
      make test-podcasts` green; coverage at or above the module floors;
      `make generate` only if a `Package.swift` changed (none expected here).

## Gotchas

- **Null guid is the common case, not the exception.** Every row last refreshed
  before phase 21-11 has `podcast_guid == NULL`, and many real feeds never publish
  the tag. The guid branch MUST require a non-null, non-empty guid; otherwise a
  null-guid subscribe could "match" another null-guid row and wrongly merge two
  unrelated shows. Guard with `if let guid = parsed.podcastGUID, !guid.isEmpty`.
- **`NULL` matching in SQL.** `Column("podcast_guid") == nil` does not behave like
  a value comparison; that is exactly why `fetchByPodcastGUID` takes a
  non-optional and callers never pass an empty guid. Do not "helpfully" make it
  optional.
- **Shared guid is a real misconfiguration.** Some networks reuse one
  `podcast:guid` across multiple shows. The non-unique index tolerates it, and
  `fetchByPodcastGUID` is deterministic (lowest `id`), so a shared guid degrades
  to "re-point the first matching row" rather than crashing or picking randomly.
  Never assume guid is one-to-one with a show.
- **etag reset on URL change is mandatory.** Carrying the old URL's `http_etag` /
  `http_last_modified` to a new origin can yield a bogus 304 on the next refresh
  (validators are origin-specific), silently starving the moved feed of updates.
  Null both on rehost.
- **Never auto-merge distinct guids, never merge on null guid.** Only an exact
  non-null guid equality triggers a re-point, and only of the `feed_url` of a
  single existing row. There is no path that combines two rows or two guids; the
  rehost is an in-place URL change of one row, nothing more.
- **Use `update`, not `upsertByFeedURL`, for the rehost branch.**
  `upsertByFeedURL` keys on `feed_url` and would insert under the new URL (the
  duplicate we are eliminating). The rehost updates by `id`.
- **`refresh` is not in scope.** A show's `feed_url` changing under refresh would
  require re-keying mid-refresh and is out of scope; refresh keeps resolving by
  `podcast_id`. Feed moves are caught at the next subscribe or via the redirect
  capture, which is sufficient.
- **No upward imports.** Everything is `Persistence` (migration, repository read)
  and `Podcasts` (subscribe logic); neither imports UI or Playback, and the only
  edge used is the existing `Podcasts -> Persistence` one.

## Handoff

When this lands: subscribing to a show that has moved to a new feed URL (or that
permanently redirects) updates the existing subscription in place instead of
creating a duplicate, keyed on the `podcast:guid` parsed and stored since phase
21-11, with episode state preserved because `podcast_id` is stable. `feed_url`
remains the identity whenever the guid is absent, and distinct guids are never
merged. The behaviour is silent by design; a future UI slice could surface a
localized "show moved" notice off the `podcast.subscribe.guidRehost` log event
without changing this logic. This is the last lettered slice of Phase 21-12;
with it, `podcast:guid` backs identity across feed-URL changes as the 21-12
overview's Handoff promised.
