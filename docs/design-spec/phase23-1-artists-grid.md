# Phase 23-1: Shared Card Infrastructure + Artists Grid

> Depends on: `phase23-0-overview.md` (read it first; it is the contract).
> Binding docs: `docs/design-spec/_standards.md`,
> `docs/design-spec/localization.md`.

## Goal

Everything shared (view-mode enum, mosaic engine, card + grid components, the
artist cover query) plus the first consumer: `ArtistsView` gains a Grid mode
with a toolbar toggle, persisted via `artists.viewMode`, default List.

## Non-goals

Genres/composers (23-2). View menu and destination modes (23-3). Keyboard
grid navigation parity with `AlbumsGridView`.

## Implementation plan (ordered, committable steps)

1. **`CollectionViewMode`** in
   `Modules/UI/Sources/UI/Browse/CollectionViewMode.swift` exactly as the
   overview defines it.

2. **Generalize the mosaic engine.** Move/rename
   `PlaylistMosaicGenerator.swift` to
   `Modules/UI/Sources/UI/Components/CoverMosaicGenerator.swift` per the
   overview: `mosaic(paths:version:sideLength:)`, cache cap 512, compose logic
   unchanged. Migrate `PlaylistDetailViewModel` (passes
   `version: updatedAt`). Existing playlist mosaic tests (if any) and
   snapshots must stay green; if the generator has no direct unit tests today,
   add them now (compose 1-4 images, cache identity, cap clears).

3. **Persistence query.** `AlbumRepository+CollectionCards.swift` with
   `fetchCoverArtPathsByAlbumArtist(maxPerArtist:)` per the overview sketch.
   Persistence tests: art-less albums excluded, deterministic order
   (year DESC then title), respects `maxPerArtist`, nil album-artist rows
   (compilations) excluded from this map.

4. **Card + grid components.** `CollectionCard.swift` and
   `CollectionCardGrid.swift` in `Modules/UI/Sources/UI/Components/` per the
   overview contract (model, metrics mirrored from `AlbumsGridView`,
   accessibility contract, optional context-menu builder). The card requests
   its mosaic from `CoverMosaicGenerator` in a `.task` keyed on the path list
   and renders the placeholder tile until it arrives (and when it never
   arrives, i.e. zero covers).

5. **ArtistsView integration.**
   - `@AppStorage("artists.viewMode") private var viewMode: CollectionViewMode = .list`.
   - Toolbar: segmented `Picker` (icons `list.bullet` / `square.grid.2x2`)
     next to the existing `SortMenu`, localized `help` + accessibility labels.
   - Grid mode builds `[CollectionCardModel]` from the already-loaded
     `vm.sortedArtists` (or equivalent), `vm.albumCounts`, `vm.trackCounts`,
     plus the new cover-path map, loaded alongside the existing fetches in
     `ArtistsViewModel.load()`. Sort order follows the active `SortMenu`
     choice, identical to list mode.
   - Card open: `library.selectDestination(.artist(id))`; snapshot
     `lastVisitedArtistID` first (same as the list row path, PR #360 wiring).
   - Context menu: "Remove Artist from Library" parity with the list row.
   - Scroll restore: re-center the last-visited artist on return, mirroring
     the `AlbumsGridView` `ScrollPosition` pattern.
   - List mode remains the exact existing code path.
   - If `ArtistsView.swift` approaches the 500-line ceiling, extract the grid
     content into `ArtistsGridContent.swift` beside it.

6. **Localization.** New keys (final wording at implementer's judgment,
   these are the intent): "View as list", "View as grid", "Choose how this
   view is displayed", per-section hint "Opens this artist's albums and
   songs". Add to `Localizable.xcstrings`, run `make pseudolocale`.

## Definitions & contracts

All in `phase23-0-overview.md`; produce them verbatim where specified.

## Context7 lookups

None required. Every pattern used here (GRDB grouped fetch, `LazyVGrid`,
`@AppStorage` enum, actor cache) already exists in-repo; copy in-repo idiom.

## Dependencies

None. No SPM or Homebrew changes.

## Test plan

- Persistence: the query tests from step 3 (`make test-persistence`).
- UI unit: `CoverMosaicGenerator` tests from step 2.
- Snapshots (`make test-ui`): `CollectionCard` with 4 covers, 1 cover, and
  placeholder; light and dark. A small fixed-size `CollectionCardGrid`
  snapshot. Use checked-in fixture images (`Tests/Fixtures/` conventions).
- Source-convention tests (host-less UI facts, existing pattern):
  - `ArtistsView` contains `@AppStorage("artists.viewMode")`.
  - `ArtistsView` presents the segmented view-mode `Picker`.
  - The grid open path snapshots `lastVisitedArtistID` and calls
    `selectDestination(.artist`.
- en-XA pseudolocale coverage stays green after `make pseudolocale`.
- Remember `make generate` if new files were added under
  `Modules/UI/Tests/UITests/ViewModelTests/`.

## Acceptance criteria

- [ ] Artists view toggles List / Grid; choice survives relaunch; default is
      List and list mode is visually unchanged.
- [ ] Cards render mosaic / single cover / placeholder correctly; VoiceOver
      reads one element per card with name + counts.
- [ ] Sort menu reorders the grid live.
- [ ] Clicking a card opens the artist; returning restores scroll position.
- [ ] Playlist mosaics still render (generator migration is invisible).
- [ ] All gates green; one commit, suggested message:
      `feat(ui): add card-grid view mode to Artists (#363)`.

## Gotchas

- The mosaic actor is off-main; the card must hop results back via
  `@MainActor` state and tolerate cell reuse (guard the task against a stale
  path list before assigning).
- `ArtistsViewModel` is `@Published`-based (ObservableObject); keep the new
  cover-path map `@Published private(set)` like `albumCounts`.
- Do not observe the mosaic cache from SwiftUI; request-and-set only.

## Handoff

23-2 consumes `CollectionCard`, `CollectionCardGrid`, `CollectionViewMode`,
and `CoverMosaicGenerator` unchanged. If you found their APIs wanting while
building Artists, fix them here, not there.
