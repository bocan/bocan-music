# ADR-049: Podcast features - Overview and contract

> Depends on: `ADR-048-feedkit-upgrade.md` (FeedKit on 10.4.0; `transcript_url`
> and `podcast_guid` populated). Builds on the whole ADR-037 feature set.
>
> Read `_standards.md` and `ADR-037-podcasts.md` first, then this file. **This
> file is the contract** for the lettered sub-ADRs `ADR-050` through
> `ADR-058`. Each sub-ADR implements one slice; this overview records the
> agreed scope, the shared facts they all build on, and the build order.

## Agreed scope (this is the decision record)

All candidate features from the original proposal are greenlit **except** the
"deeper Podcasting 2.0" research item (`podcast:person`, `podcast:soundbite`,
`podcast:value`), which is explicitly out of scope for now. Specific decisions
baked into the sub-ADRs:

- **Build the supplementary `podcast:` parser now** (ADR-050). It fills
  `funding_url` and `chapters_url`, which FeedKit 10.4.0 does not parse. We will
  keep watching FeedKit for official support and retire the supplement if it
  lands upstream (the supplement is deliberately localized so it is easy to pull).
- **Transcripts are stored in full in the database** (not just the URL), and the
  stored transcript is **cleaned up 30 days after its episode is listened to or
  marked as listened to**. See "Shared semantics" below.
- **The funding link asks for confirmation** before opening the external URL.
- **No notifications** (they do not work reliably on the target machine). Instead,
  ADR-055 adds an **unread-episode count badge on the podcast artwork** in the
  grid, plus a **"Mark all as played"** action to clear it.

## The lettered sub-ADRs (build order)

Build in letter order. `a` is a hard prerequisite for `c` and `d`; the rest are
independent and can be reordered if needed.

| File | Slice | Module(s) | New migration? |
|------|-------|-----------|----------------|
| `ADR-050-namespace-supplement.md` | Supplementary `podcast:` parser (funding + chapters URLs, funding label) | Podcasts | maybe (funding label) |
| `ADR-051-transcripts.md` | Transcript fetch + full DB storage + viewer + 30-day cleanup | Podcasts, Persistence, UI | yes (transcript cache table) |
| `ADR-052-funding.md` | "Support this show" affordance with confirmation | UI, App | no |
| `ADR-053-chapters.md` | Chapter list in Now Playing + seek-to-chapter | Podcasts, UI, App | no (fetch on demand) |
| `ADR-054-continue-listening.md` | Cross-show "Continue Listening" rail | Persistence, UI, App | no (index optional) |
| `ADR-055-unread-badges.md` | Unread count badge on artwork + "Mark all as played" | Persistence, UI, App | no (index optional) |
| `ADR-056-opml.md` | OPML import / export | Podcasts, UI, App | no |
| `ADR-057-per-show-settings.md` | Per-show speed / sort / retention overrides | Persistence, Podcasts, UI | yes (podcasts columns) |
| `ADR-058-guid-identity.md` | `podcast:guid`-based identity and de-duplication | Persistence, Podcasts | yes (index) |

### Migration numbering across these sub-ADRs (read this)

Five sub-ADRs add a migration: a (`funding_text`), b (transcript table), e (an
optional recency index), h (per-show columns), and i (a `podcast:guid` index).
`M024` is the highest migration registered today. Each sub-ADR was drafted
in isolation, so several name their migration `M025`; **those numbers are
illustrative placeholders, not assignments**. At implementation time, do what the
house style already requires: read the top of
`Modules/Persistence/.../Migrations/Migrator.swift`, take the next free integer,
name the file and enum to match, register it after the current head, and bump the
two `MigrationTests` assertions (the count and the schema version) to the new
head. Implemented in letter order, the migration-bearing slices land as a, b,
(e if added), h, i, so they would become `M025`, `M026`, optionally `M027`,
`M028`, `M029`. Verify against `Migrator.swift` rather than trusting the number
printed in any sub-ADR.

## Shared facts the sub-ADRs build on

### Modules and seams (no upward imports; mirror the existing wiring)

- **Podcasts** owns feed fetch/parse, search, subscribe/refresh, downloads, and
  artwork cache. Key pieces: `FeedFetcher` (conditional GET, size cap, `User-Agent`,
  cancellation), `FeedParser` (FeedKit 10.4.0 -> `ParsedFeed` / `ParsedEpisode`),
  `PodcastService` (the facade), the `HTTPClient` protocol seam (inject a
  `URLProtocol` stub in tests), `PodcastArtworkCache` (the pattern to copy for any
  new on-disk cache), and `FeedURL.canonicalKey` (the dedupe identity).
- **Persistence** owns the tables and typed repositories: `PodcastRepository`,
  `EpisodeRepository`, `EpisodeStateRepository`; records `Podcast`,
  `PodcastEpisode`, `PodcastEpisodeState`, and the joined read model
  `EpisodeListItem` (episode + optional state). Migrations are numbered and
  append-only under `Migrations/`, registered in `Migrator.swift`; `M024` is the
  highest at this writing. Any new migration uses the next free integer and bumps
  the two assertions in `MigrationTests` (the count and the schema version).
- **UI** never imports `Podcasts`. It talks through protocols declared in
  `Modules/UI/Sources/UI/Browse/Podcasts/PodcastSeams.swift`:
  `PodcastLibraryDataSource` (reads: `subscribedPodcasts`, `episodes(podcastID:)`,
  `observeSubscribed`, `observeEpisodes(podcastID:)`, `episodeCounts`),
  `PodcastActions` (mutations: subscribe/unsubscribe/refresh/reorder/play, and
  already `markPlayed`, `markUnplayed`, `markAllPlayed(podcastID:)`,
  download/removeDownload), and `PodcastSearchProviding` (search + detail). The
  **App** layer implements these over `PodcastService` + `QueuePlayer` and injects
  them into `LibraryViewModel`. New UI capabilities extend these protocols and are
  implemented in App; UI consumes seam types from `Persistence`.
- **Playback** holds the `PodcastEpisodeResolving` seam and the
  `PlayableSource.podcast` case; the App implements the resolver over
  `PodcastService`. Chapters seek (ADR-053) goes through `QueuePlayer`, not by
  reaching into the engine.

### Per-episode state (the join key for cleanup, unread counts, continue-listening)

`podcast_episode_state` is keyed by `(podcast_id, guid)` and carries
`play_position`, `play_state` (`unplayed` / `inProgress` / `played`),
`last_played_at`, `completed_at`, and the download columns. A missing row means
unplayed at position 0. This table is the data source for sub-ADRs b (cleanup
clock), e (continue listening), and f (unread counts + mark-all).

### What ADR-050 (the supplement) produces

The supplementary parser extends `ParsedFeed` / `ParsedEpisode` so the rest of the
pipeline is unchanged downstream:

- `ParsedFeed.fundingURL` (already exists) gets populated from `podcast:funding`,
  and a new `ParsedFeed.fundingText` carries the human label. These map to the
  `podcasts.funding_url` (existing) and a new `funding_text` column.
- `ParsedEpisode.chaptersURL` (already exists) gets populated from
  `podcast:chapters`, mapping to the existing `podcast_episodes.chapters_url`.

The supplement runs over the same bytes `FeedFetcher` returned, after FeedKit, and
merges by `guid`. It must be non-fatal: a failure logs at debug and yields no
extra fields, never failing the main parse, and never touching the FeedKit path.

## Shared semantics

### Transcript cleanup clock (sub-ADRs b and f interact)

A stored transcript is deleted **30 days after its episode became "listened"**.
"Listened" means `play_state = 'played'`, whether reached by playback completion
or by an explicit mark-played (including the bulk "Mark all as played" in
ADR-055). The clock is `completed_at` when set, else `last_played_at`. The
cleanup is a periodic sweep (run at app launch and after the refresh fan-out, the
same hooks `FeedRefreshScheduler` uses) that deletes transcript rows whose joined
state shows played-and-older-than-30-days. ADR-055's "Mark all as played"
therefore starts the cleanup clock for every episode it marks; call this out in
both specs so the interaction is intentional, not surprising.

### Unread count (ADR-055)

"Unread" = episodes for a show with no state row or `play_state != 'played'`
(i.e. `unplayed` or `inProgress` both count as unread). The grid badge shows that
count per show; "Mark all as played" sets every episode of the show to `played`.
The seam already exposes `markAllPlayed(podcastID:)`; ADR-055 adds an
`unplayedCounts() -> [Int64: Int]` style read to `PodcastLibraryDataSource` (and a
matching observation) rather than computing it view-side.

## Cross-cutting rules (every sub-ADR)

- **Localization:** all chrome (labels, buttons, menu items, accessibility
  labels, toasts, errors, confirmation dialogs) routes through `L10n` in the UI
  module with keys in `Resources/Localizable.xcstrings`; run `make pseudolocale`
  after adding keys. Feed-sourced content (transcript text, chapter titles,
  funding label, show/episode titles) is rendered verbatim, never localized.
- **Testing:** Swift Testing, 80% per-module coverage, no network (stub via
  `URLProtocol` or the `HTTPClient` mock), fixtures checked in under the module's
  `Tests/.../Fixtures/`.
- **Sandbox:** opening an external URL (funding) uses `NSWorkspace.open`; no new
  entitlement. Treat all feed-sourced URLs as untrusted: only open `http`/`https`,
  and show the destination host in the confirmation.
- **Build/test gates:** `make format && make lint && make build && make
  test-<module>` per the touched modules before each commit; `make generate` after
  any `Package.swift` / `project.yml` change; one logical change per commit,
  Conventional Commits scoped to the module.

## Non-goals (still)

- `podcast:person` / `podcast:soundbite` / `podcast:value` (deferred research).
- Notifications of any kind.
- Video podcasts, podcast hosting, AI summaries, cross-device subscription sync.

## Handoff

When all of `ADR-049-{a..i}` land: funding and chapters URLs are parsed and
surfaced; transcripts are viewable and self-cleaning; a Continue Listening rail
and unread badges read the state table; OPML moves subscriptions in and out;
per-show overrides exist; and `podcast:guid` backs identity across feed-URL
changes. If FeedKit later parses the `podcast:` namespace fully, ADR-050's
supplement can be removed and `FeedParser` reads the fields directly.
