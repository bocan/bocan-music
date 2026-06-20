# Phase 21-12-f: Unread badges and Mark all as played

> Depends on: `phase21-12-podcast-features.md` (the contract; read "Shared
> semantics" -> "Unread count" and the cleanup interaction),
> `phase21-7-ui-podcasts-home.md` (subscribed grid, `PodcastCell`), and
> `phase21-12-b-transcripts.md` (the 30-day cleanup clock this slice can start).
> Read `_standards.md` and `phase21-0-overview.md` first.

## Goal

Show how many episodes of each subscribed show the user has not finished, as a
count badge on the artwork in the subscribed grid, plus a one-action "Mark all
as played" to clear it. The count is read from the state table through a new
seam method (never computed view-side), mirroring the existing `episodeCounts`
plumbing. The mutation already exists on the seam
(`markAllPlayed(podcastID:)`); this slice adds the read, the observation, the
badge, and the grid menu item.

## Non-goals

- **No notifications of any kind** (the contract rules them out; this badge is
  the agreed substitute for "new episodes" awareness).
- No badge on the sidebar row, Dock icon, or menu bar. Grid cell only.
- No new "unread" play state: it is derived from `play_state`, not stored.
- No per-episode unread toggle in the grid (per-episode mark-played already
  exists in the episode list from phase 21-9; this slice is show-level only).
- No migration. An optional covering index is discussed under Data model and is
  skipped by default.

## Outcome shape (file tree)

```
Modules/Persistence/Sources/Persistence/Repositories/
    EpisodeStateRepository.swift     (+ unplayedCounts, observeUnplayedCounts)
Modules/Podcasts/Sources/Podcasts/
    PodcastService.swift             (+ unplayedCounts, observeUnplayedCounts over the repo)
Modules/UI/Sources/UI/Browse/Podcasts/
    PodcastSeams.swift               (+ both methods on PodcastLibraryDataSource)
    PodcastsViewModel.swift          (+ podcastUnplayedCounts + observation task)
    PodcastsGridView.swift           (+ UnreadBadge overlay, Mark all as played menu item)
    UnreadBadge.swift                (new: the count-pill overlay view)
    Resources/Localizable.xcstrings  (+ badge a11y label; reuse "Mark All as Played")
Modules/Persistence/Tests/PersistenceTests/   (count-query tests)
Modules/UI/Tests/UITests/ViewModelTests/      (badge + menu source-convention tests, VM count test)
```

`PodcastService` already conforms to `PodcastLibraryDataSource` via the
retroactive conformance in `App/AppPodcastActions.swift`, so adding the methods
to the service satisfies the App side; no new App file is needed.

## Data model

No new table or column. Per the contract, an episode is unread when it has no
state row OR `play_state != 'played'` (so `unplayed` and `inProgress` both count;
only `played` is excluded). One LEFT JOIN aggregate, computed in Persistence:

```sql
SELECT e.podcast_id AS podcast_id, COUNT(*) AS cnt
FROM podcast_episodes e
LEFT JOIN podcast_episode_state s
    ON s.podcast_id = e.podcast_id AND s.guid = e.guid
WHERE s.play_state IS NULL OR s.play_state != 'played'
GROUP BY e.podcast_id
```

This mirrors `EpisodeRepository.fetchAllPodcastCounts` (a `Row.fetchAll` +
`GROUP BY` returning `[Int64: Int]`) but lives on `EpisodeStateRepository`
because the predicate is state-defined. A fully-played show is absent from the
dictionary (not a zero entry); the badge hides on absent or zero.

Optional index: the unique `podcast_episodes_guid_idx (podcast_id, guid)` backs
the join and the state primary key `(podcast_id, guid)` backs the lookup, so the
join is index-served both sides. Run `EXPLAIN QUERY PLAN` first. Only a real
large-library scan would justify a partial index
(`... ON podcast_episode_state(podcast_id) WHERE play_state != 'played'`) in its
own numbered migration; default is no index, no migration.

## Implementation

### Count read + observation (Persistence)

Add to `EpisodeStateRepository`, next to the write `markAllPlayed`:

```swift
/// Unread counts keyed by podcast ID. Unread = no state row or
/// play_state != 'played'. Shows with zero unread are absent.
public func unplayedCounts() async throws -> [Int64: Int]
public func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error>
```

`unplayedCounts` runs the SQL above inside `database.read`; `observeUnplayedCounts`
runs the same query inside `database.observe` so it tracks both tables (the
two-table observation the joined list model already uses is the pattern). Decode
exactly like `fetchAllPodcastCounts` (`row["podcast_id"] as Int64`,
`row["cnt"] as Int`).

### Seam + App + service

Extend `PodcastLibraryDataSource` in `PodcastSeams.swift`, right after
`episodeCounts()`:

```swift
func unplayedCounts() async throws -> [Int64: Int]
func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error>
```

`PodcastService.unplayedCounts()` / `observeUnplayedCounts()` delegate to the new
`EpisodeStateRepository` methods (the service already holds the state repo),
mirroring `PodcastService.episodeCounts()`. UI never imports Podcasts; the seam
is the only contact surface. Update the test stubs (`StubPodcastLibrary` in
`PodcastsViewModelTests.swift` and the inline stub in
`PodcastsViewModelSearchTests.swift`) to satisfy the widened protocol.

### View model wiring (UI)

In `PodcastsViewModel`, add a published dictionary beside `podcastEpisodeCounts`:

```swift
@Published public private(set) var podcastUnplayedCounts: [Int64: Int] = [:]
```

Populate it from `library.unplayedCounts()` in `loadSubscribed()` (alongside the
existing `episodeCounts()` fetch). Keep it live from a dedicated observation task
consuming `observeUnplayedCounts()`, with the same `Task.checkCancellation()` /
`CancellationError` handling as the other tasks, a separate
`nonisolated(unsafe) var unplayedCountsTask: Task<Void, Never>?` handle, and a
cancel in `deinit`. Relying on the observation (rather than re-fetching inside
the subscribed stream as `episodeCounts` does) means a mark-all write zeroes the
entry automatically, so the badge clears with no manual refresh.

### Badge overlay (UI)

Add `UnreadBadge.swift`: a small capsule pill (accent fill, white numerals,
monospaced digits) sized for one to three digits. In `PodcastCell` (in
`PodcastsGridView.swift`), overlay it on the artwork `Group` at `.topTrailing`,
gated on a non-zero count:

```swift
.overlay(alignment: .topTrailing) {
    if let n = self.unreadCount, n > 0 {
        UnreadBadge(count: n)
            .padding(6)
            .accessibilityLabel(L10n.string("\(n) unplayed episodes"))
    }
}
```

`PodcastCell` gains an `unreadCount: Int?` parameter fed from
`vm.podcastUnplayedCounts[id]`, exactly like `episodeCount` is fed from
`vm.podcastEpisodeCounts[id]`. The badge carries its own a11y label and folds
into the cell's existing `.accessibilityElement(children: .combine)`. Hidden
entirely when nil or zero (no "0" pill).

### Mark all as played (UI)

The grid's `contextMenu(for:)` gains an item near the existing Refresh entry:

```swift
Button(L10n.string("Mark All as Played")) {
    Task { await self.library.podcastActions?.markAllPlayed(podcastID: id) }
}
```

The same `markAllPlayed(podcastID:)` already backs the show toolbar via
`vm.markAllPlayed()`; the grid calls the seam directly with the cell's `id`
because the grid is not scoped to a `currentShow`. A `.confirmationDialog`
("Mark all episodes as played?", destructive confirm) is optional but
recommended since the action is bulk. Note here and in code:
**mark-all sets every episode to `played`, stamping `completed_at`/`last_played_at`,
which starts the 30-day transcript cleanup clock from sub-phase b for each one.**
This is intentional (the contract calls it out); do not exempt mark-all from the
sweep.

### Localized chrome

New keys in `Resources/Localizable.xcstrings` (UI module):

- `"%lld unplayed episodes"` (badge a11y label) as a **plural-aware** string so
  VoiceOver reads "1 unplayed episode" vs "5 unplayed episodes". The visible pill
  shows a bare numeral via a formatter and is not itself a plural string.
- Reuse the existing `"Mark All as Played"` key (already used by the show
  toolbar); do not add a duplicate.
- Confirmation copy only if the dialog is added.

Run `make pseudolocale` after adding keys (the en-XA coverage test fails
otherwise). Feed content (show titles, authors) stays verbatim.

## Context7 lookups

None. This slice uses GRDB APIs already in this repo (`Row.fetchAll`,
`database.read`, `database.observe`) and SwiftUI overlay/accessibility modifiers
already in the UI module. No new dependency, so no Context7 lookup is needed.

## Test plan

Persistence (`make test-persistence`, in-memory `Database`):

- `unplayedCounts` counts an episode with **no state row** as unread.
- counts `unplayed` and `inProgress` as unread; **excludes** `played`.
- mixed show reports only the not-played count; a fully-played show is absent
  (not a zero entry).
- `markAllPlayed(podcastID:)` then `unplayedCounts` reports the show cleared.
- `observeUnplayedCounts` emits initially and re-emits after a mark-played write.

UI (`make test-ui`):

- VM test: with a stub `unplayedCounts`, `loadSubscribed()` populates
  `podcastUnplayedCounts`.
- source-convention (`#filePath`) on `PodcastsGridView.swift` / `UnreadBadge.swift`:
  the overlay is at `.topTrailing`, gated on non-zero, and has an
  `accessibilityLabel`.
- source-convention: the grid context menu contains "Mark All as Played" wired
  to `markAllPlayed(podcastID:)`.
- `L10nTests`: the unplayed-episodes a11y key has plural variants and en-XA
  coverage.

No network in any test (the count is pure SQL over in-memory state).

## Acceptance criteria

- [ ] `EpisodeStateRepository.unplayedCounts()` / `observeUnplayedCounts()` exist,
      implement the no-row-or-not-played definition, and omit zero-count shows.
- [ ] `PodcastLibraryDataSource` exposes both; the service implements them; UI
      does not import Podcasts.
- [ ] `PodcastsViewModel.podcastUnplayedCounts` is populated on load and kept
      live via an observation task cancelled in `deinit`.
- [ ] Each grid cell shows a count badge on the artwork when unread > 0, hidden
      at zero, with a plural-aware localized a11y label.
- [ ] The grid context menu offers "Mark all as played"; invoking it clears the
      badge for that show via the observation, no manual refresh.
- [ ] Spec and code note that mark-all starts the 30-day cleanup clock
      (sub-phase b).
- [ ] All new chrome is localized; `make pseudolocale` is run and en-XA passes.
- [ ] `make format && make lint && make build && make test-persistence && make
      test-ui` are green.

## Gotchas

- **Badge perf on large libraries.** One `GROUP BY` for all shows, never a query
  per cell. Keep the cell lookup `vm.podcastUnplayedCounts[id]` (a dictionary
  read) inside `PodcastCell`; never fetch in `body` or per `ForEach` iteration. A
  grid of hundreds of shows issues one query per emission.
- **Plural localization.** The visible pill shows a bare numeral (formatter); the
  a11y label is the plural-variant string. Do not concatenate a number with a
  localized "episodes" literal: that breaks non-trailing-plural languages and
  trips the no-bare-literal lint.
- **Cleanup-clock interaction.** Mark-all sets `play_state = 'played'` and stamps
  `completed_at`/`last_played_at` for every episode, exactly what arms sub-phase
  b's 30-day transcript sweep. By design and cross-referenced in both specs; add
  no carve-out, and expect a binge-marked show's transcripts to age out 30 days
  later.
- **Definition drift.** "Unread" is purely `play_state`-derived; unrelated to
  download state or `last_refreshed_at`. Do not conflate it with "new since last
  refresh" (that would need a seen-at concept this slice avoids).
- **Observation churn.** Reuse the `database.observe` two-table pattern; do not
  poll on a timer. A mark-played write already wakes the observation.

## Handoff

After this slice the subscribed grid shows a live unread count per show backed by
`EpisodeStateRepository.unplayedCounts`/`observeUnplayedCounts` through the
`PodcastLibraryDataSource` seam, and "Mark all as played" clears it from the grid
context menu (and still works from the show toolbar). The new read joins the same
state table sub-phase b (cleanup) and sub-phase e (continue listening) read, so
the three stay consistent. Mark-all intentionally starts the 30-day cleanup
clock. No migration was added; if a future profile shows the count scanning on a
very large library, add the partial index from Data model in its own migration.
