# ADR-094: Play History Page

> Depends on: ADR-005 (library UI, the destination model), ADR-081 (sidebar rows as
> accessibility elements), ADR-082 (surface crawl registries), #450 and #455
> (`TableUpdatePlan`, the shared table update path), #543 (rows stay mounted
> through a refresh).
> Binding docs: `_standards.md`; the schema-discipline and testing sections of
> the root `CLAUDE.md`.
> Requested by the maintainer, 2026-09-22.

Measured on the maintainer's library on 2026-09-22 with a read-only query
(`sqlite3 -readonly`), release copy of 2.17.1. Every number below comes from
that query and is reproducible with the probe in the Test plan.

## Goal

Show the play history Bòcan already keeps. Since the first schema, every
qualifying play of a library song has written one row to `play_history`
(`track_id`, `played_at`, `duration_played`, `source`), and nothing reads
those rows back as a list. Recently Played and Most Played read only the
per-track counters, so they show each song once. This ADR adds a **History**
destination to the Recents section of the sidebar: one row per play, newest
first, with the song's title, artist, album, how much of it was played, and
when.

The page has its own search. Typing in the toolbar search field while History
is open filters the plays by the song's text, and nothing else: the library
query is untouched, and the history query is discarded the moment History is
left, in either direction. Entering History always starts with an empty
field.

## Non-goals

- **No new play data.** Radio and podcasts still write nothing (ADR-078 and
  ADR-042 both promise this to users), and Subsonic plays scrobble without a
  local row. The page shows local library plays. Radio scrobbling is a
  separate decision, to be its own ADR.
- **No skips.** A skip increments `tracks.skip_count` and writes no history
  row, so there is nothing per skip to show.
- **No editing.** No delete-a-play, no clear-history. A page that shows a
  record must not also be the place that quietly destroys it; if deletion is
  ever wanted it gets its own confirm-and-explain flow.
- **No export.** Later, if at all.
- **No imported listens in slice 1.** The Last.fm import (`imported_listens`)
  is 63,967 rows on the maintainer's library against 877 local plays. Merging
  the two is a paging and identity problem of its own; it is slice 3 here,
  and the first two slices must not assume it.
- **No change to the global search.** `LibraryViewModel.searchQuery`, its
  debounce, its back and forward capture, and every view that reads it keep
  their behaviour byte for byte. History adds a second, unrelated query.
- **No menu item.** The sidebar row is the entry point (the reasoning is in
  the Handoff). A View item can be added later without touching anything
  here.

## Outcome shape

New files:

| File | Holds |
|---|---|
| `Modules/Persistence/Sources/Persistence/Repositories/PlayHistoryRepository.swift` | `PlayHistoryRepository`: the joined read, newest first, with an optional FTS5 filter. |
| `Modules/Persistence/Sources/Persistence/Records/PlayHistoryRow.swift` | `PlayHistoryRow`: one play joined to its song's display text. `Sendable`, `FetchableRecord`. |
| `Modules/Persistence/Tests/PersistenceTests/PlayHistoryRepositoryTests.swift` | Repository tests on an in-memory database. |
| `Modules/UI/Sources/UI/ViewModels/HistoryViewModel.swift` | `HistoryViewModel`: rows, `rowsVersion`, `query`, its own debounce, load. |
| `Modules/UI/Sources/UI/History/HistoryView.swift` | The destination: table, loading, empty and no-results states. |
| `Modules/UI/Sources/UI/History/HistoryTable.swift` | `NSViewRepresentable` over `NSTableView`, keyed by the play id. |
| `Modules/UI/Sources/UI/History/HistoryTableCoordinator.swift` | Delegate, diffable data source, context menu. |
| `Modules/UI/Tests/UITests/ViewModelTests/HistoryViewModelTests.swift` | View-model tests, host-less. |
| `Modules/UI/Tests/UITests/ViewModelTests/HistorySearchRoutingTests.swift` | The routing contract, on `LibraryViewModel`. |
| `UITests/Surfaces/HistorySurfaceTests.swift` | The E2E journey. |

Changed files:

| File | Change |
|---|---|
| `Modules/UI/Sources/UI/SidebarDestination.swift` | `case history` in the Recents group. `Codable` by synthesis; a new case decodes cleanly from older blobs (the enum's own doc says so). |
| `Modules/UI/Sources/UI/AppRoot/Sidebar.swift` | Fourth row in the Recents section, after Most Played. |
| `Modules/UI/Sources/UI/AppRoot/ContentPane.swift` | `case .history: HistoryView(...)`. |
| `Modules/UI/Sources/UI/Browse/SmartFolders.swift` | `displayTitle` arm. |
| `Modules/UI/Sources/UI/ViewModels/LibraryViewModel.swift` | `history: HistoryViewModel`; the routed `searchText` accessor; the clear on entry and exit inside `selectDestination`. |
| `Modules/UI/Sources/UI/ViewModels/LibraryViewModel+Navigation.swift` | `loadDestination` arm; `parentDestination` and `isPlausibleContainer` return nil and false for `.history` (top level); the Esc fall-through clears the history query when History is showing. |
| `Modules/UI/Sources/UI/AppRoot/RootView.swift` | `.searchable(text:)` binds to the routed accessor, not `$vm.searchQuery`. |
| `Modules/UI/Sources/UI/AppRoot/TypeToSearchMonitor.swift` | The seed character goes through the routed accessor. |
| `Modules/UI/Sources/UI/Accessibility/A11yIdentifiers.swift` | `A11y.Sidebar.history`, `A11y.History.table`, `A11y.History.emptyState`, `A11y.History.noResults`. |
| `Modules/UI/Sources/UI/Resources/Localizable.xcstrings` | New keys, then `make pseudolocale`. |
| `UITests/Menus/MenuInvoker.swift` | `"History": "sidebar.history"` in `sidebarIdentifiers`. |
| `UITests/Audits/IdentifierAuditTests.swift` | `"History"` in the destinations walk. |
| `UITests/Surfaces/SurfaceCompletenessTests.swift` | The new surface's identifiers registered, or listed as deferred with a reason, per ADR-082. |
| `docs/data-dictionary-notes.json` | `traces` entries for `play_history.duration_played` and `play_history.source` (see Gotchas). |
| `README.md`, `website/` | History listed with the other Recents. |
| `CHANGELOG.md` | The release note, under Unreleased. |

No migration. The page reads `play_history` as it stands.

## What carries over from previous specs

- **ADR-005**: the content area is a destination switch, not a
  `NavigationStack`. History is a destination like Recently Played, so it
  gets back, forward, Esc and state restore for free.
- **#450, #455**: a table's `updateNSView` decides per-row work from a
  `rowsVersion` and a `TableUpdatePlan`. `HistoryTable` uses the generic plan
  with the play id as its row key, the way `SubsonicSongTable` uses the
  server row string. It does not reuse `TrackTable`, and the reason is
  structural: `TrackTable` deduplicates row ids because a diffable snapshot
  needs them unique, and a history is exactly a list where one song appears
  many times. Keying by `play_history.id` makes every row unique without a
  workaround.
- **#543**: rows first, loading second. A refresh with rows on screen keeps
  the table mounted.
- **ADR-081**: a tag-selected sidebar row is invisible to accessibility
  without an explicit identifier. The new row gets one like the other three.
- **ADR-082**: every identified control on a new surface is either crawled
  or listed as deferred with a reason. `SurfaceCompletenessTests` fails
  otherwise.
- **The 2026-09-21 gotcha** ("A SwiftUI view torn down while focused stops
  right-clicks reaching AppKit tables"): the History page contains no
  `.focusable()` view, so it cannot reach that state, and its context menu
  test says so.

## Implementation plan

### Facts the plan rests on (measured 2026-09-22)

| Fact | Value |
|---|---|
| `play_history` rows | 877 |
| Distinct songs played | 826 |
| First and last play | 2026-05-08 to 2026-09-21 |
| `source` values | `queue` only |
| Orphan rows (`track_id` not in `tracks`) | 0, by construction: the key is `ON DELETE CASCADE` |
| `tracks` | 15,222 |
| `imported_listens` | 63,967 |

Consequences. At 877 rows over four and a half months, a full load with no
paging is correct for slices 1 and 2; the table's per-row cost is what #450
measured at 14,000 rows, an order of magnitude away. `source` is a constant
and is not shown. There are no orphans and there cannot be: M001 declares
`track_id ... REFERENCES tracks(id) ON DELETE CASCADE`, so Remove from
Library and the conflict resolver delete a song's plays with the song. A
history page is the first surface that makes that loss visible, and it is
open decision 1 in the Handoff, not something this ADR changes. Slice 3's
numbers are the reason it is a separate slice.

### Slice 1: the destination and the table

Persistence:

- `PlayHistoryRow`: `playID`, `trackID`, `playedAt` (epoch seconds),
  `durationPlayed` (seconds), `title`, `artistName`, `albumName`,
  `trackDuration`. The last four come from a `LEFT JOIN` on `tracks`, then
  `artists` and `albums`. A left join, not an inner one, so a row whose song
  is missing lists with empty text rather than vanishing. Through the app
  that cannot happen, because of the cascade; the join is defence for a
  database opened with `foreign_keys` off.
- `PlayHistoryRepository.recent(limit: Int? = nil, matching: String? = nil)`.
  Newest first on `played_at`, which M001 already indexes descending. With a
  non-empty `matching`, add `AND play_history.track_id IN (SELECT rowid FROM
  tracks_fts WHERE tracks_fts MATCH ?)`, escaping the term with the existing
  `SQL.escapeFTSTerm`. That is the same index and the same escaping the
  library search uses, so a song findable in Songs is findable in History
  with the same text.

UI:

- `HistoryViewModel` (`@MainActor @Observable`): `rows: [PlayHistoryRow]`
  with `rowsVersion` incremented in `didSet`, `isLoading`, `query: String`,
  and `load()`. It owns a 250 ms debounce on `query`, mirroring
  `LibraryViewModel.makeSearchQuerySubscription`, and never touches
  `LibraryViewModel.searchQuery`.
- `HistoryTable` and `HistoryTableCoordinator`: a third AppKit table,
  patterned on `SubsonicSongTable` (its own coordinator, its own
  `NSMenuDelegate` menu, `TableUpdatePlan<Int64, Int64>` keyed by play id).
  Columns, in order: Played (date and time, via `Formatters.shortDate` plus a
  time), Title, Artist, Album, Played For (the played duration against the
  song's duration, as `3:12 of 4:05`). Sortable by Played only in this slice;
  the natural order of a history is time.
- Double-click plays the song, as every table does. The context menu offers
  Play Now, Play Next, Add to Queue, Go to Album, Go to Artist, Show in
  Finder and Get Info, each acting on the song under the pointer, built from
  the same closures `TracksView+Actions` assembles. A row whose song is
  missing gets no menu.
- `HistoryView`: rows first, then loading, then one of two empty states:
  "No plays yet" when the table is empty with no query, and the standard
  no-results state when a query matches nothing.
- The sidebar row: `sidebarRow(.history, symbol: "clock.badge.checkmark",
  label: L10n.string("History"))`, inside the existing
  `if self.vm.sectionExpansion.recents`.

### Slice 2: the independent search

This is the part the maintainer asked for by name, so it is its own slice
with its own contract.

- `LibraryViewModel` gains a routed accessor:

  ```swift
  /// The text in the toolbar search field. On History it is the history
  /// query; everywhere else it is the library query. The two never mix.
  public var searchText: String {
      get { self.selectedDestination == .history ? self.history.query : self.searchQuery }
      set {
          if self.selectedDestination == .history {
              self.history.query = newValue
          } else {
              self.searchQuery = newValue
          }
      }
  }
  ```

  `RootView` binds `.searchable(text:)` to `$vm.searchText`, and
  `TypeToSearchBackground` writes its seed character through the same
  property. Nothing else changes: `searchQuery` keeps its `@Published`
  debounce, its readers, and its back and forward capture.
- `selectDestination` clears on both edges. Leaving History:
  `history.query = ""` before the destination changes. Entering History:
  `history.query = ""` after it changes. The library query is not touched by
  either edge, so a filter that was active on Songs is still there when the
  user goes to History and back through the sidebar.
- The back and forward stacks capture `searchQuery`, which is the library
  query. On History that is whatever it was when History was entered, and it
  is restored on return exactly as today. The history query is never
  captured, which is the contract: it does not survive navigation.
- Esc on History with a non-empty history query clears it, mirroring the
  existing fall-through in `handleDrillOut` for the library query. With an
  empty query Esc does nothing, as it does on the other top-level rows.
- ⌘F focuses the field as it does everywhere, via `requestSearchFocus`.

### Slice 3: imported listens

Optional, and a decision the maintainer takes after slices 1 and 2 are
in. The Last.fm import is most of the maintainer's listening record, so a
History page that omits it will feel incomplete; but 63,967 rows is past
the point where one snapshot is acceptable, and imported rows have artist
and title text with an optional `track_id`, not a song.

If taken: a Source filter on the page (Local, Imported, Both; default
Local), a `UNION ALL` on the two tables in the shape
`LibraryStatsRepository+ListeningTime.allPlays` already uses, and a
bounded window (the most recent 2,000, with a Load Older control) rather
than the whole set. The FTS filter cannot apply to imported rows; they
filter on their own text with `LIKE`. Nothing in slices 1 and 2 may assume
this slice: no `source` column in the row, no union in the repository.

## Behavioural definitions and contracts

1. **One row per play.** A song played three times lists three times, each
   with its own time. Row identity is `play_history.id`.
2. **Newest first.** Ties on `played_at` (two plays in the same second) break
   on `id` descending, so the order is total and stable across reloads.
3. **Removal erases, today.** Removing a song from the library deletes its
   plays (`ON DELETE CASCADE`, M001), so History keeps no trace of it. This
   is existing behaviour made visible, not a choice of this ADR; it is open
   decision 1 in the Handoff. The read is still a `LEFT JOIN`, so a row
   whose song is missing lists with empty text rather than vanishing.
4. **The history query is independent.** At no time does a write to
   `history.query` change `searchQuery`, or the reverse. This is testable in
   the view model with no view.
5. **Entering History starts empty.** However History is reached (sidebar,
   back, forward, state restore), `history.query` is `""` when the page
   appears.
6. **Leaving History discards.** Whatever was typed on History is gone once
   any other destination is selected, and is not on the back stack.
7. **The library query survives a visit.** A non-empty `searchQuery` on
   Songs is unchanged after going to History and back by the sidebar, and
   restored after going and coming back by ⌘[ and ⌘].
8. **Search matches by the song's text**, through the same FTS5 index and
   escaping as Songs. A term that finds a song in Songs finds its plays in
   History; a term that finds nothing in Songs finds nothing in History.
9. **Refresh keeps the place.** A new play arriving while History is open
   inserts one row at the top and moves nothing else; selection and scroll
   position are unchanged (#543, and the plan's `.structural` path with a
   changed id set).
10. **The debounce is per query.** A keystroke on History reloads History
    only, 250 ms after the last keystroke, and never reloads the library
    destination.

## Context7 lookups

Before writing code, and with the latest version of each:

- GRDB 7: `FetchableRecord` on a joined `SQLRequest`, `ValueObservation` on a
  request that joins three tables (for the live insert in contract 9), and
  FTS5 `MATCH` with a bound argument inside a subquery.
- Swift Testing: `#expect` with async view-model state; confirm the pattern
  the existing `ViewModelTests` use for `@Observable` changes.
- SwiftUI `searchable(text:)`: that a computed `Binding` from a property
  with a custom setter is supported, and what `searchFocused` needs.

## Dependencies

- No new packages. GRDB 7 and Swift Testing are already pinned.
- `SQL.escapeFTSTerm` is `internal` to `Persistence`; the repository lives
  in the same module, so no access change.
- `Formatters.shortDate(epochSeconds:)` is `public` in `UI`.
- `TrackContextMenuActions` and `TracksView+Actions` are reused, not copied.

## Test plan

Persistence, `make test-persistence`, in-memory database
(`Database(location: .inMemory)`):

- Three plays of one song list three rows, newest first, ids descending on
  a shared second.
- Deleting a track deletes its plays (contract 3): insert a play, delete the
  track, check the play is gone. The test pins the cascade, so a later
  change to it is a deliberate one. The `LEFT JOIN` on the song tables is
  covered by a song with no artist and no album, which lists with those
  columns empty. A play of a missing song is not reachable from a test:
  the wrapper's `write` runs inside a transaction, where
  `PRAGMA foreign_keys` is a no-op, and its writer is private.
- `matching:` finds plays of a song by title, by artist, by album, and
  returns nothing for a term with no song; a term with FTS syntax characters
  is escaped, not an error.
- `limit:` caps the result.

UI view model, `make test-ui` (and `make generate` first, because the
`ViewModelTests` directory is globbed into the Xcode bundle):

- Contracts 4 to 7 on `LibraryViewModel` with a stub repository: write
  through `searchText` on Songs and check `searchQuery` moved and
  `history.query` did not; select `.history` and check the reverse; select
  `.history` with a library query set, then `.songs`, and check the library
  query is intact and the history query is empty; `goBack` from History
  restores the library query.
- Contract 10 on `HistoryViewModel`: two writes to `query` inside 250 ms
  produce one load.
- A source-convention test that `Sidebar.swift` contains the `.history` row
  inside the Recents section, and that `RootView.swift` binds `.searchable`
  to `searchText`, not `searchQuery`, so a later revert of the routing shows
  up in CI.

E2E, `UITests/Surfaces/HistorySurfaceTests.swift`, run by hand with
`make test-e2e`:

- Play a fixture track past the threshold (the E2E fixtures are 60 s, so
  30 s is enough), open History, and check one row with that title.
- Type in the search field on History; check the row filters; press Esc;
  check the field is empty and the row is back.
- Type on Songs, go to History, check the field is empty; go back with ⌘[
  and check the Songs text is restored.
- Right-click the row and wait on "Show in Finder", which only the context
  menu has (the 2026-09-21 lesson: Play Now is also a menu bar item).
- Register the new identifiers in `SurfaceCompletenessTests`, or list them
  as deferred with a reason.

The probe for the facts table:

```
sqlite3 -readonly "$HOME/Library/Application Support/Bocan/library.sqlite" \
  "SELECT COUNT(*), COUNT(DISTINCT track_id) FROM play_history;"
```

## Acceptance criteria

- History is a fourth row under Recents and opens a table of plays, newest
  first, one row per play, with the columns in slice 1.
- Every contract in the Behavioural definitions has a passing test at the
  level named for it.
- `make format`, `make lint`, `make build`, `make test-coverage`,
  `make test-ui` (with the macOS 27 snapshot skip) and `make pseudolocale`
  are green.
- `make data-dictionary` shows `play_history.duration_played` with a reader.
- The release note is under Unreleased, in the listener's voice.
- README and the website list History with the other Recents.

## Gotchas

- **Do not reuse `TrackTable`.** It deduplicates row ids
  (`applyStructuralChange`, "NSDiffableDataSourceSnapshot requires unique
  item identifiers"), which would collapse repeated plays of one song into
  one row. Key the new table by play id.
- **`play_history.duration_played` has no reader today**, and
  `data-dictionary.md` shows its "read by" cell blank. This ADR supplies the
  first reader; add the `traces` note keyed `play_history.duration_played`
  in `docs/data-dictionary-notes.json` and regenerate. `source` stays
  unread; note it as `n/a (constant "queue")` so the blank is explained
  rather than left.
- **Everything cascades.** `play_history.track_id` is `ON DELETE CASCADE`
  (M001), so Remove from Library and `ConflictResolver` erase a song's plays
  with the song. This page is the first surface that shows that loss. Do
  not change it here: keeping plays for a removed song means a nullable
  `track_id` plus snapshot title, artist and album columns, which is a
  migration with its own review, and it is the shape `imported_listens`
  already has. It is open decision 1 in the Handoff.
- **The routing accessor must not be `@Published`.** `searchText` is
  computed over two stored properties that are already observed; giving it
  its own publisher would double-fire the debounce.
- **Do not add `.focusable()` to anything on this page** (2026-09-21
  gotcha). The table is AppKit and handles its own focus.
- **Sidebar rows carry no `.help()`** and the audit skips them; do not add
  one to the new row alone.
- **Adding `HistoryViewModelTests.swift` needs `make generate`** before
  `make test` sees it (`Modules/UI/CLAUDE.md`).
- **String Catalog churn**: after adding keys run `make pseudolocale`; if an
  Xcode build reorders the catalog, run it again rather than hand-fixing.
- **`#expect` with a key-path `allSatisfy`** breaks the Xcode bundle build;
  compare sets instead (existing gotcha).

## Handoff

Why the sidebar and not a menu. View holds modes of the main window and
Tools holds actions over the library; History is content, read not run,
and it is the per-play form of the three rows already under Recents. A
person will look there first, and the destination model gives it back,
forward, Esc and restore for nothing.

Order of work: slice 1, slice 2, then stop and look at it with the real
library before deciding slice 3. Each slice is a branch and a PR;
`fix/`-typed for none of them, `feat(ui):` for 1 and 2. Slice 2 must not
merge without the routing tests, since it is the part that is easy to
silently undo.

Open decisions for the maintainer, in the order they block:

1. Whether history should survive Remove from Library. Today it does not:
   the cascade deletes a song's plays with the song, and this page will be
   the first place a person can see that. Keeping them is a separate ADR
   (nullable `track_id`, snapshot text columns, a migration), and it should
   be decided before the page ships, because the release note has to say
   which it is.
2. Slice 3 at all, and if so the default Source filter.
3. Whether "Played For" should show `3:12 of 4:05` or a percentage.
4. Whether Recently Played should keep its 90-day window now that the full
   record is one row below it, or be left exactly as it is.
