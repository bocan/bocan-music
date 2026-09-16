# ADR-093: Table Sort Chains

> Depends on: ADR-005 (persisted UI state), #450 (`TableUpdatePlan`, the
> table's update path), #455 (the shared plan across both tables).
> Binding docs: `_standards.md`; the testing sections of the root `CLAUDE.md`.
> Requested by the maintainer, 2026-09-16.

Measured on a Mac running macOS 26 with Xcode 27. Every claim below is
reproducible with the probe in the Test plan.

## Goal

Sorting the Songs table by a column sorts by that column *and then by
something sensible*, instead of leaving every tie to chance. Clicking a second
and third header composes a real chain rather than silently dropping the
oldest key. The chain survives a relaunch.

## Non-goals

- A multi-field sort dialog (MusicBee's "sort by multiple fields"). The
  click-composed chain plus per-column defaults covers the need; a dialog is a
  separate feature with its own UI contract.
- Sort-specific fields: articles stripped so "The Cure" files under C, and
  diacritic folding. That is a schema change with a scanner backfill and it
  deserves its own ADR. Today's comparators use `.localizedStandard`, which
  already folds case and diacritics for comparison but keeps the leading
  article.
- The Subsonic song table. It has its own coordinator and no SwiftUI selection
  binding; it can adopt this once the local table proves it.
- The Albums, Artists, Genres and Composers views. They sort a different unit
  and already have their own sort menus.
- Server-side ordering. The local library sorts in memory, and 15 000 rows
  sort fast enough that moving it into SQL buys nothing yet.

## Outcome shape

Slice 1, stop truncating:

- `Modules/UI/Sources/UI/Browse/TrackTableCoordinator.swift` (`syncSortIfNeeded`
  writes the whole chain; `handleSortDescriptorsDidChange` caps and dedupes)
- `Modules/UI/Sources/UI/Browse/TrackTable+Helpers.swift` (the cap constant)
- `Modules/UI/Tests/UITests/ViewModelTests/TrackTableSortChainTests.swift` (new)

Slice 2, the chains:

- `Modules/UI/Sources/UI/Browse/TrackSortChain.swift` (new: the global chain,
  the overrides, and the compose function)
- `Modules/UI/Sources/UI/Browse/TrackTable+ColSpecs.swift` (`tieBreakers` on
  `ColSpec`)
- `Modules/UI/Sources/UI/Browse/TrackTableCoordinator.swift` (compose on click)
- `Modules/UI/Tests/UITests/ViewModelTests/TrackSortChainTests.swift` (new)

Slice 3, persistence:

- `Modules/UI/Sources/UI/ViewModels/LibraryViewModel.swift` (`UIStateV2` gains
  `sortChain`)
- `Modules/UI/Sources/UI/ViewModels/TracksViewModel.swift` (restore a chain)
- `Modules/UI/Tests/UITests/ViewModelTests/LibraryDestinationPersistenceTests.swift`
- `docs/design-spec/README.md` (index row)

## What carries over from previous specs

- `TracksViewModel.defaultSortOrder` is already a three-key chain, artist →
  album → track number. The concept exists; it is only the launch default, and
  the first header click destroys it.
- `TracksViewModel.applySort` already sorts on the whole array
  (`rows.sort(using: order)`), so nothing downstream needs changing for a
  longer chain.
- `TracksViewModel.setSort(columns:)` already seeds a multi-key sort from an
  ordered list; nothing in the table path calls it.
- `UIStateV2` decodes with `decodeIfPresent` for fields added after V1, so a
  new field needs no migration and old payloads keep working.

## Implementation plan

### Facts the plan rests on (measured 2026-09-16)

1. `NSTableView` accumulates the chain itself. A header click prepends the
   clicked column's descriptor to `sortDescriptors`, keeps the rest behind it,
   and dedupes by key. No code of ours is involved, and there is no cap.
2. We read all of it. `handleSortDescriptorsDidChange`
   (`TrackTableCoordinator.swift:188`) maps the whole array, not just
   `.first`.
3. We then throw most of it away. `syncSortIfNeeded`
   (`TrackTableCoordinator.swift:197`) builds a one-element array from
   `sortOrder.first` and assigns it over the table's list, on every
   `updateNSView`. Driving the real functions through a click sequence:

   | Click | `sortDescriptors` after AppKit | `sortOrder` we apply | after `syncSortIfNeeded` |
   |---|---|---|---|
   | Track | `[trackNumber]` | `[trackNumber]` | `[trackNumber]` |
   | Album | `[albumName, trackNumber]` | `[albumName, trackNumber]` | **`[albumName]`** |
   | Artist | `[artistName, albumName]` | `[artistName, albumName]` | **`[artistName]`** |

   Two keys is the ceiling, and the third click pushes the oldest out.
4. `rows.sort(using:)` is not a stable sort. Ties land in whatever order the
   sort algorithm leaves them, so the "click columns in reverse priority"
   folk remedy works only by luck and only until the data changes.
5. The table has 31 columns, 30 of them sortable
   (`TrackTable+ColSpecs.swift`). A hand-written chain per column is not
   maintainable, and most of them do not want their own.
6. `UIStateV2` persists a single `(sortColumn, sortAscending)` pair
   (`LibraryViewModel.swift:25`), so even a working chain would collapse on
   relaunch.

### Slice 1: stop truncating

1. `syncSortIfNeeded` maps the entire `sortOrder` to descriptors and assigns
   that, instead of `sortOrder.first`. The existing equality guard and the
   `isSyncingSort` re-entry guard stay exactly as they are.
2. `handleSortDescriptorsDidChange` applies the two rules AppKit does not:
   dedupe by sort key, keeping the first occurrence, and cap at
   `TrackTable.maxSortKeys = 4`.
3. Why four: the fourth key is already invisible to a reader, the header can
   only show one arrow, and each key costs a comparison per row pair across
   15 000 rows.

### Slice 2: the chains

1. One global chain, artist → album → disc → track, appended after whatever
   the user clicked. This is the answer to "31 columns is too many to write
   chains for": almost every column wants the same tie-breakers, because the
   question a listener asks of a sorted stat column is "whose is it, and from
   what".
2. Dedupe does most of the work. Sorting by Artist yields artist → album →
   disc → track with no override, because the clicked key is dropped from the
   chain when it appears there. The same holds for Album, Disc and Track. Only
   four columns want something different:

   | Column | Chain |
   |---|---|
   | Title | title → artist → album |
   | Album | album → disc → track → artist |
   | Genre | genre → artist → album → disc |
   | Year | year → artist → album → disc |

   Everything else, from Play Count to Bit Depth, takes the global chain.
3. The chain lives in the column table: `ColSpec` gains
   `tieBreakers: [TrackSortColumn]?`, defaulting to nil, meaning "use the
   global". A new column therefore cannot forget to have one.
4. Composition on a click: the user's explicit keys first, in AppKit's order,
   then the clicked column's chain appended, then dedupe, then cap. An
   explicit key the user chose always outranks a tie-breaker.
5. A tie-breaker inherits ascending order regardless of the clicked column's
   direction. Sorting play count descending still wants artist A to Z beneath
   it.

### Slice 3: persistence

1. `UIStateV2` gains `sortChain: [PersistedSortKey]`, a list of
   `(column, ascending)` pairs, decoded with `decodeIfPresent`.
2. When `sortChain` is absent, fall back to the legacy `sortColumn` and
   `sortAscending`, so an existing payload restores as a one-key sort and then
   gains its chain on the next click. Keep writing the legacy pair as well,
   set from the chain's head, so a downgrade does not lose the primary column.
3. Restore through `TracksViewModel.setSort(columns:)`, which already exists.

## Behavioural definitions and contracts

- **Accumulation is AppKit's.** We never build the chain ourselves; we read
  `sortDescriptors`, constrain it, and write it back unchanged in order.
- **Cap and dedupe.** At most four keys, no key twice, first occurrence wins.
- **Chain rule.** The applied order is: the user's clicked keys in AppKit's
  order, then the clicked column's tie-breakers, deduped, capped.
- **Tie-breaker direction.** Always ascending, whatever the clicked column's
  direction.
- **Round trip.** What `syncSortIfNeeded` writes back must equal what
  `handleSortDescriptorsDidChange` would read, or the next click composes on a
  different list than the user sees.
- **Persistence.** The chain survives a relaunch. An old payload restores its
  single column and is not discarded.

## Context7 lookups

AppKit is not on Context7, and the two behaviours this rests on (the header
click's prepend-and-dedupe, and `NSTableView.sortDescriptors` semantics) are
measured in the Test plan rather than read from documentation.

Prior art worth reading before slice 2, not as a dependency: Navidrome's
repository sort mapping, where `_sort=artist` expands to an ordered list ending
in disc and track, and release date precedes album name so a discography reads
chronologically. Bòcan already speaks to Navidrome, so matching its chains
keeps a federated library consistent with itself.

## Dependencies

- Slice 2 depends on slice 1: composing a chain is pointless while the write
  back truncates it.
- Slice 3 depends on slice 2 only for the shape of what it stores.
- No new packages, pins or Homebrew additions.

## Test plan

The probe that produced fact 3 builds a `TrackTableCoordinator` with the
harness already in `TrackTableDragTests`, attaches a real `NSTableView` with
sortable columns, and drives the click sequence, reproducing AppKit's
prepend-and-dedupe in a helper because a header click cannot be synthesised
host-less:

```swift
let clicked = NSSortDescriptor(key: key, ascending: true)
var rest = tableView.sortDescriptors.filter { $0.key != key }
rest.insert(clicked, at: 0)
tableView.sortDescriptors = rest
coordinator.handleSortDescriptorsDidChange(in: tableView)
coordinator.syncSortIfNeeded(sortOrder: box.sort)
```

Slice 1:

- Three clicks compose three keys, and the table's descriptors still hold all
  three after `syncSortIfNeeded`.
- A fifth click caps the chain at four, dropping the oldest.
- Clicking a column already in the chain moves it to the head rather than
  duplicating it.
- `syncSortIfNeeded` with an empty order still clears the header arrow.
- The round trip: read, write back, read again, and the order is unchanged.

Slice 2:

- Sorting by Artist yields artist → album → disc → track, with no duplicate
  artist key.
- Sorting by Play Count descending yields play count descending, then artist,
  album and disc ascending.
- Each of the four overridden columns yields its documented chain.
- A column with no override and no `tieBreakers` takes the global chain: a
  parameterised test over every sortable column asserts the composed chain is
  capped, deduped and starts with the clicked column.

Slice 3:

- A chain survives a save and restore.
- A payload with no `sortChain` restores its legacy single column.
- The legacy pair is still written, matching the chain's head.

All slices: `make format`, `make lint`, `make build`, `make test-coverage` and
`make test-ui`, then `/slice-review` and the PR.

## Acceptance criteria

- Clicking Track, then Album, then Artist leaves the table sorted by artist,
  then album, then track, and all three arrows' worth of order survives a
  fourth unrelated click only by pushing the oldest key out.
- A single click on Artist, from a freshly launched app, gives the same
  reading order as the current default sort.
- Sorting by Play Count groups equal counts by artist and album rather than by
  import order.
- The chain is still there after a relaunch.

## Gotchas

- **The truncation is the whole bug.** Slice 1 is three lines of behaviour
  change; resist rewriting the sort path around it.
- **`sort(using:)` is not stable.** Do not lean on the previous order
  surviving a re-sort; that is what makes the reverse-click remedy unreliable
  and why the chain has to be explicit.
- **The round trip is load-bearing.** `syncSortIfNeeded` writing a different
  list than it read is exactly today's bug in a new costume. The round-trip
  test exists to catch that.
- **`isSyncingSort` must keep wrapping the write.** Assigning
  `sortDescriptors` re-enters `handleSortDescriptorsDidChange`; without the
  guard, the cap and dedupe would run against their own output.
- **Direction belongs to the clicked key only.** Inheriting a descending
  direction into the tie-breakers reverses artists inside every group and reads
  as a bug.
- **31 columns.** Anything requiring a per-column decision must default, or
  the next column added will be the one nobody wrote a chain for.

## Handoff

Run each slice in its own session on the branch `feat/search-order`, from the
commit that carries this ADR. Paste the prompt, then the whole of this file.

Slice 1 prompt:

> Implement slice 1 of docs/design-spec/ADR-093-table-sort-chains.md on the
> branch feat/search-order. Start with the round-trip test so the truncation is
> pinned before it is removed. Follow the root CLAUDE.md gates and the UI module
> testing rules. Do not touch slices 2 or 3. Commit when green; do not push.

Slice 2 prompt:

> Implement slice 2 of docs/design-spec/ADR-093-table-sort-chains.md on the
> branch feat/search-order, after slice 1. Start with the parameterised test
> over every sortable column so the global default is proven before the
> overrides are written. Commit when green; do not push.

Slice 3 prompt:

> Implement slice 3 of docs/design-spec/ADR-093-table-sort-chains.md on the
> branch feat/search-order, after slice 2. Persist the chain in UIStateV2 with
> a legacy fallback. Then run /slice-review and open the PR.
