# Phase 23-3: View Menu + Destination Album Modes + Docs

> Depends on: `phase23-0-overview.md` (the contract) and committed,
> gates-green 23-1 and 23-2.

## Goal

Three finishing pieces:

1. View-menu items mirroring the List / Grid toggle for whichever collection
   listing is currently shown.
2. A Songs / Albums switch on the genre and composer destinations (the
   ticket author's literal ask: browse a genre by its albums, not a flat
   track list), persisted per section.
3. README + website documentation; close out issue #363.

## Non-goals

Keyboard shortcuts for the menu items (the `cmd-shift-1..9` server-jump and
other bindings make collisions likely; ship without shortcuts and revisit on
demand). Smart-folder album modes (explicit overview non-goal).

## Implementation plan

### 1. View menu

- `App/BocanCommands.swift` is at the 500-line lint ceiling. Extract an
  existing cohesive command group into `App/BocanCommands+<Group>.swift`
  first (pure move, own commit) if needed, then add a small "View as"
  section: two items, "as List" and "as Album Grid", checkmarked
  radio-style from the active section's mode.
- Follow that file's existing conventions exactly: menu titles are
  grandfathered bare literals in `App/` (no String Catalog there); plain
  `let` view models; no observation of high-frequency state (root `CLAUDE.md`
  constraint). Read `library.selectedDestination` and the `@AppStorage`
  values when the menu opens; write the appropriate key
  (`artists.viewMode` / `genres.viewMode` / `composers.viewMode`) on click.
  The views react via their own `@AppStorage` bindings; no new plumbing.
- The items are disabled when the current destination is not one of the
  three collection listings.
- Add/extend the App-side menu convention test if one exists for
  `BocanCommands` (check `Modules/UI/Tests/UITests/ViewModelTests/` and the
  Xcode `BocanTests` bundle for the established pattern before inventing
  one).

### 2. Destination album modes

- New raw-representable enum `CollectionDetailMode: String { case songs,
  albums }` beside `CollectionViewMode`.
- `AlbumsViewModel` gains filtered loads mirroring the `TracksViewModel`
  pattern (`load(genre:)`, `load(composer:)`), backed by new repository
  queries in `AlbumRepository+CollectionCards.swift`:

  ```swift
  /// Albums having at least one non-disabled track in `genre`,
  /// ordered by title.
  public func fetchAll(genre: String) async throws -> [Album]
  public func fetchAll(composer: String) async throws -> [Album]
  ```

- `ContentPane`'s `.genre(name)` / `.composer(name)` destinations read
  `genres.detailMode` / `composers.detailMode` (`@AppStorage`, default
  `.songs`). Songs renders the existing `TracksView` path unchanged. Albums
  renders the albums grid for that filter; opening an album routes to the
  existing `.album(id)` destination. Reuse `AlbumsGridView` if its API
  permits a caller-filtered load without contortions; otherwise a thin
  wrapper around the same cells/metrics is acceptable, but do not fork the
  grid styling.
- The Songs / Albums control is a segmented `Picker` in the destination's
  toolbar (icons `music.note.list` / `square.grid.2x2`), localized help and
  accessibility labels, same conventions as the 23-1 toggle.

### 3. Docs

- README: extend the three-pane-browser bullet with the grid modes and the
  genre/composer album browsing.
- Website: `website/src/docs.njk` gains a short "Browsing by album" note;
  check `website/src/_data/features.json` for a natural mention. No em
  dashes anywhere in either (repo rule).
- Do not close #363 in the commit message with `fixes` unless the release
  branch policy says otherwise; reference it (`(#363)`) and close it when
  2.3.0 ships.

## Context7 lookups

None required.

## Dependencies

None.

## Test plan

- Persistence: `fetchAll(genre:)` / `fetchAll(composer:)` tests: disabled
  tracks excluded, distinct albums, title order, NULL album ids ignored
  (`make test-persistence`).
- Source-convention tests: `ContentPane` (or the destination views) reads
  `genres.detailMode` and `composers.detailMode`; the destination toolbar
  presents the Songs / Albums `Picker`; `BocanCommands` contains the two
  menu items.
- Full gates including `make test-ui`, `make pseudolocale` if the catalog
  changed, `make generate` if test files were added.

## Acceptance criteria

- [ ] View menu shows "as List" / "as Album Grid" with the correct check
      for the visible section, disabled elsewhere; clicking updates the view
      live and persists.
- [ ] A genre or composer destination can show its albums as a grid;
      clicking one opens the normal album detail; the Songs mode is
      byte-identical to today's behaviour and remains the default.
- [ ] README and website mention the feature; no em dashes introduced.
- [ ] All gates green; suggested commits:
      `feat(app): mirror collection view modes in the View menu (#363)` and
      `feat(ui): browse genre and composer destinations by album (#363)`
      plus `docs: document collection grid browsing (#363)` (or fold docs
      into the second commit per the one-logical-change rule).

## Gotchas

- The menu writes `UserDefaults` keys the views observe via `@AppStorage`;
  both sides must agree on the raw values, which is why the enums live in
  one place (UI module) and `App` references them through the UI import.
- `AlbumsGridView` currently binds to the shared full-library
  `AlbumsViewModel`; a filtered load on the shared instance leaks into the
  Albums destination (same shared-VM trap as the tracks table, see repo
  history on smart-playlist sorting). Prefer a locally owned
  `AlbumsViewModel` instance (or equivalent) for the filtered destination;
  do not corrupt the main Albums view's contents.
- Reduce Motion: grid appearance should not add new animations beyond what
  `AlbumsGridView` already does.

## Handoff (phase close-out)

After this slice: note in the PR/issue that smart-folder album modes
(Recently Added as albums) were deliberately deferred; file a follow-up
issue if the ticket author still wants them. Phase 23 is then complete and
2.3.0-ready.
