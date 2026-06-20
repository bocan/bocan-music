# Phase 21-12-e: Continue Listening rail

> Depends on: `phase21-12-podcast-features.md` (the contract). Builds on phase
> 21-1 (`podcast_episode_state` + repositories), phase 21-5 (the
> `PodcastEpisodeResolving` resolver, which already seeks to the saved position),
> and phase 21-7 (the Podcasts home view + UI seam protocols). Read
> `_standards.md`, `phase21-0-overview.md`, and the contract above first.

## Goal

Add a cross-show "Continue Listening" rail to the Podcasts home view: one
horizontal row of episode cards drawn from every subscribed show, listing the
episodes the user has started but not finished, most-recent activity first.
Tapping a card resumes through the existing play path. The rail reads
`podcast_episode_state` directly (no per-show fan-out), updates live as positions
are written, and hides itself when empty.

## Non-goals

- No new sidebar destination or standalone screen; one rail on the existing home
  view, above the subscribed grid.
- No ordering beyond `last_played_at` descending (no "up next" rules, no
  duration-weighting, no grouping by show).
- No swipe-to-dismiss. An episode leaves the rail only when marked played or
  unplayed.
- No change to position write-back, resume, or `markPlayed` (phase 21-5). This
  slice only reads the state they produce.
- No required migration. A recency index is optional (see Data model).

## Outcome shape (file tree)

```
Modules/Persistence/Sources/Persistence/
  Records/ContinueListeningItem.swift          (new: read model)
  Repositories/EpisodeStateRepository.swift    (edit: query + observation)
  Migrations/M025PodcastStateRecency.swift     (OPTIONAL index only)
  Migrations/Migrator.swift                     (edit only if M025 added)
Modules/Persistence/Tests/PersistenceTests/
  ContinueListeningTests.swift                 (new)
  MigrationTests.swift                          (edit only if M025 added)
Modules/UI/Sources/UI/Browse/Podcasts/
  PodcastSeams.swift                           (edit: two data-source methods)
  ContinueListeningRail.swift                  (new: the rail)
  PodcastsHomeView.swift                       (edit: mount the rail)
  PodcastsViewModel.swift                      (edit: load + observe + resume)
Modules/UI/Sources/UI/Resources/Localizable.xcstrings (edit: rail chrome)
Modules/UI/Tests/UITests/...                   (new source-convention test)
App/AppPodcastActions.swift                    (no change: empty conformance covers it)
```

## Data model

### Read model (Persistence)

A flat `Sendable` value carrying enough to render a card and resume, so the UI
never re-fetches. It lives in Persistence because UI consumes Persistence types
and must not import Podcasts.

```swift
public struct ContinueListeningItem: Sendable, Hashable, Identifiable {
    public var podcastID: Int64
    public var guid: String
    public var showTitle: String          // podcasts.title (feed content, verbatim)
    public var episodeTitle: String       // podcast_episodes.title (verbatim)
    public var artworkPath: String?       // episode art if present, else show art
    public var artworkURL: String?        // remote fallback for Artwork(...)
    public var playPosition: Double       // resume point, seconds
    public var duration: Double?          // episode duration, seconds (may be nil)
    public var lastPlayedAt: Double       // sort key; never nil for inProgress rows
    public var id: String { "\(self.podcastID):\(self.guid)" }
}
```

### The query

A three-table join filtered to in-progress state, newest activity first. State
is the driving table because the filter and the sort both live there:

```sql
SELECT s.podcast_id, s.guid, s.play_position, s.last_played_at,
       e.title AS episode_title, e.duration,
       COALESCE(e.artwork_path, p.artwork_path) AS artwork_path,
       COALESCE(e.artwork_url,  p.artwork_url)  AS artwork_url,
       p.title AS show_title
FROM podcast_episode_state s
JOIN podcast_episodes e ON e.podcast_id = s.podcast_id AND e.guid = s.guid
JOIN podcasts          p ON p.id = s.podcast_id
WHERE s.play_state = 'inProgress' AND p.subscribed = 1
ORDER BY s.last_played_at DESC, s.guid ASC
LIMIT ?
```

- INNER JOIN to `podcast_episodes`, not LEFT: a state row whose episode dropped
  out of the feed has nothing to render or resume, so it is correctly excluded.
- `play_state = 'inProgress'` is the whole filter: `unplayed` (no row, or never
  started) and `played` (finished) are both excluded, matching the contract.
- `LIMIT` caps the rail (default 25, a named constant): a glance, not a backlog.
- `guid ASC` is a stable tiebreak for equal `last_played_at` (see Gotchas).

### Optional index (NOT required)

The contract marks this optional. The filtered set (in-progress, subscribed) is
small, so the sort cost is negligible; default to shipping without it. If
profiling later shows it matters, add as `M025PodcastStateRecency.swift`, the
next free integer after `M024PodcastGUID` in `Migrator.swift`:

```sql
CREATE INDEX podcast_episode_state_recency_idx
    ON podcast_episode_state(last_played_at DESC);
```

Adding it is a schema change: bump both `MigrationTests` assertions
(`schemaVersion()` 24 to 25 and `migrator.migrations.count` 24 to 25). Do not
add it speculatively.

## Implementation

### Repository (Persistence)

Add two methods to `EpisodeStateRepository` (it already owns this table),
mirroring the one-shot + observation pairing of
`PodcastRepository.observeSubscribed` and `EpisodeRepository.observeListItems`:

```swift
public func continueListening(limit: Int = 25) async throws -> [ContinueListeningItem]
public func observeContinueListening(limit: Int = 25)
    async -> AsyncThrowingStream<[ContinueListeningItem], Error>
```

Both run the SQL through a file-private `FetchableRecord` row decoder (the
pattern of `EpisodeListRow`). The one-shot uses `database.read`; the observation
uses `database.observe { ... }`, which GRDB re-evaluates on any change to the
three joined tables, so a position write, `markPlayed`, unsubscribe, or feed
prune all re-emit. Log at `.persistence` per op.start/op.end; no `try?` without
an `else`.

### Seam (UI declares, App implements)

Extend `PodcastLibraryDataSource` in `PodcastSeams.swift` with two methods
returning the Persistence read model:

```swift
func continueListening() async throws -> [ContinueListeningItem]
func observeContinueListening() async -> AsyncThrowingStream<[ContinueListeningItem], Error>
```

`PodcastService` gains forwarding methods over its `stateRepo`, so the existing
empty `extension PodcastService: PodcastLibraryDataSource {}` in
`App/AppPodcastActions.swift` keeps satisfying the protocol with no body. Play
stays on `PodcastActions.play(episode:podcast:)`; the resolver seeks to the
saved position on load, so the rail passes no position.

### View model (UI)

Add `@Published public private(set) var continueListening: [ContinueListeningItem]
= []` and `nonisolated(unsafe) var continueListeningTask: Task<Void, Never>?`
(leave the annotation as-is per the UI CLAUDE.md note; cancel in `deinit`). Fetch
once at the end of `loadSubscribed()`, then observe, assigning into the published
array exactly like `startObserveSubscribed`: `Task.checkCancellation()` in the
loop, swallow `CancellationError`, log other errors at `.warning`.

`actions.play` needs both an `EpisodeListItem` and a `Podcast`. Add `func
resume(_ item: ContinueListeningItem) async`: resolve the show from the live
`subscribed` array by `podcastID` (bail if missing), build a minimal
`EpisodeListItem` from the item's `guid`/`title`/`duration` (the resolver keys
playback off feed URL + guid, so a full content row is not needed), and call
`actions?.play`.

### The rail (UI)

`ContinueListeningRail.swift`: a `ScrollView(.horizontal)` of fixed-width cards.
Each card shows show artwork via `Artwork(artPath:)` with the same
`GradientPlaceholder` fallback as `PodcastCell`, the episode title (verbatim,
`lineLimit(2)`), and a thin `ProgressView(value:)` of `playPosition / duration`
(omit the bar when `duration` is nil or zero). Tapping calls `vm.resume(item)`.
A localized section header sits above the row.

Mount it in `PodcastsHomeView`'s idle branch, above `PodcastsGridView`, only when
non-empty:

```swift
} else {
    VStack(spacing: 0) {
        if !self.vm.continueListening.isEmpty {
            ContinueListeningRail(vm: self.vm)
            Divider()
        }
        PodcastsGridView(vm: self.vm, library: self.library)
    }
}
```

Empty handling is structural: when the array is empty the rail and its divider
are absent from the tree, so there is no empty-state copy to write for it.

### Localization

New chrome keys in `Localizable.xcstrings`: `"Continue Listening"` (header),
`"Resume \(episodeTitle)"` (per-card accessibility label; the title is feed
content interpolated into a localized format, like the existing `"\(podcast.title)
artwork"` key), and `"Double-tap to resume episode"` (hint). Show/episode/author
text is feed content, rendered verbatim. Run `make pseudolocale` after adding
keys, or the en-XA coverage test fails.

## Context7 lookups

None. First-party only: GRDB query + `ValueObservation` (the existing repository
pattern) and SwiftUI layout. No new dependency whose surface needs verifying.

## Test plan

Swift Testing, no network, in-memory `Database(location: .inMemory)`.

Persistence (`ContinueListeningTests.swift`):

- One subscribed show, three episodes (one `inProgress`, one `played`, one with
  no state row): `continueListening()` returns exactly the in-progress item with
  correct position, duration, titles, and artwork fallback (episode art when
  present, else show art).
- Recency: in-progress episodes across two shows with distinct `last_played_at`
  come back strictly descending.
- Excludes finished and unstarted even when their `last_played_at` is newer than
  an in-progress row.
- Excludes orphaned state (episode content pruned -> INNER JOIN drops it) and
  unsubscribed shows (`subscribed = 0`).
- `LIMIT` honoured (seed limit+1, assert count == limit).
- Observation: `savePosition` a new episode -> next emission contains it;
  `markPlayed` an item -> next emission drops it.

UI (host-less source-convention, reads via `#filePath`):

- `PodcastsHomeView` references `ContinueListeningRail` and gates it on a
  non-empty check.
- `ContinueListeningRail` uses a horizontal `ScrollView` and routes taps to a
  `resume` call.

If `M025` is added, update the `MigrationTests` count + schema-version assertions
in the same change.

## Acceptance criteria

- [ ] `EpisodeStateRepository.continueListening(limit:)` returns only
      `inProgress` rows for subscribed shows, joined to content, newest first.
- [ ] `observeContinueListening(limit:)` emits initially and on every change to
      the three joined tables.
- [ ] `ContinueListeningItem` lives in Persistence and carries show title,
      episode title, artwork path/url, position, duration, podcastID, guid.
- [ ] `PodcastLibraryDataSource` exposes the one-shot + observation;
      `PodcastService` forwards both; the empty App conformance still compiles.
- [ ] `PodcastsViewModel` loads + live-observes the rail and exposes `resume(_:)`
      routing to the existing `PodcastActions.play`.
- [ ] The home view shows the rail above the grid when non-empty and omits it
      (and its divider) when empty.
- [ ] Tapping a card resumes at the saved position via the existing resolver, not
      a position passed by the rail.
- [ ] All rail chrome localized; `make pseudolocale` run; feed content verbatim.
- [ ] No upward imports; UI consumes Persistence types only.
- [ ] `make format && lint && build && test-persistence && test-ui` pass (add
      `make test` if `M025` was added).

## Gotchas

- **Recency tiebreak.** Two episodes can share a `last_played_at` (same write
  tick, or imported state); without a secondary sort the order is undefined and
  the rail flickers between emissions. The `guid ASC` tiebreak makes it
  deterministic; keep it.
- **Observation cost.** The observation tracks three tables, so a position write
  every ~5 s during playback re-runs the query and re-emits. The query is small
  and capped by `LIMIT`, and the cadence is seconds not frames, so this is fine;
  do not debounce it into staleness. Do cancel the task on navigation and in
  `deinit`.
- **Resume correctness.** Do not have the rail seek. The `.podcast` source goes
  through `PodcastEpisodeResolving`, which reads `resumePosition` and seeks on
  load; a position passed from the rail would duplicate (and could fight) that.
  The rail's `playPosition` drives the progress bar only.
- **Artwork fallback.** Episode art is often nil; `COALESCE` to show art in SQL
  so a card always renders something, matching `PodcastCell`.
- **Stale show lookup.** Resolve the `Podcast` on resume from the live
  `subscribed` array, not a snapshot captured at card-build time, so a
  mid-session unsubscribe cannot resume a gone show; bail if the lookup fails.

## Handoff

After this slice the Podcasts home view leads with a cross-show Continue
Listening rail backed by `podcast_episode_state`, fed by a one-shot + observation
pair on `EpisodeStateRepository`, surfaced through two additions to
`PodcastLibraryDataSource`, and resuming through the phase 21-5 resolver. It
shares the state table with sub-phase b (transcript cleanup) and sub-phase f
(unread counts); neither writes through this read path, so they compose without
coordination. If a recency index is ever needed, it slots in as the next
migration with the `MigrationTests` bump noted above.
