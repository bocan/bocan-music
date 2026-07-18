# Phase 23-2: Genres and Composers Grids

> Depends on: `phase23-0-overview.md` (the contract) and a committed,
> gates-green 23-1 (it reuses every component 23-1 built).

## Goal

Genre and composer card queries in Persistence, then Grid modes for
`GenresView` and `ComposersView` with the same toggle + persistence pattern
as Artists (`genres.viewMode`, `composers.viewMode`, default `.list`).

## Non-goals

View menu, destination Songs / Albums modes, docs (all 23-3).

## Implementation plan

1. **Persistence queries.** Extend
   `AlbumRepository+CollectionCards.swift` with `fetchGenreCards(maxCovers:)`
   and `fetchComposerCards(maxCovers:)` returning `CollectionCardData` per
   the overview sketch. Rules: disabled tracks excluded everywhere; empty or
   NULL genre/composer excluded; `albumCount` is `COUNT(DISTINCT album_id)`
   (tracks with NULL `album_id` count toward `songCount` but contribute no
   album or cover); cover paths deduped and deterministic.

2. **Set-equality tests** (the overview's hard requirement): seed a database
   with edge rows (empty-string genre, NULL genre, a disabled track carrying
   a unique genre, a compilation album with nil album-artist) and assert the
   name set from `fetchGenreCards` equals the set returned by the exact
   `TrackRepository` fetch `GenresView` uses today. Same for composers. If
   they differ, fix the card query, never the list source.

3. **File split (expected).** `GenresComposersView.swift` is near the
   500-line ceiling. Pre-split it into `GenresView.swift` and
   `ComposersView.swift` (shared enums may stay in a small
   `GenresComposersSort.swift`). Pure move, zero behaviour change, done as
   the first UI step so the later diff is readable. Update any
   source-convention tests that reference the old path (`L10nTests` file
   lists, scroll-restore convention tests).

4. **Wire the grids.** Each view: `@AppStorage` mode, segmented toggle next
   to its `SortMenu`, grid content built from its card data (loaded next to
   the existing genre/composer fetch), placeholder symbols `tag` (genres)
   and `music.quarternote.3` (composers). Sort follows the existing
   `GenreSortOrder` / `ComposerSortOrder` (name or song count) in both modes.
   Open: `selectDestination(.genre(name))` / `.composer(name)` with the
   existing last-visited snapshot for scroll restore. No context menus.

5. **Localization**: per-section accessibility hints ("Opens this genre's
   songs", "Opens this composer's songs"); reuse everything else from 23-1.
   `make pseudolocale`.

## Context7 lookups

None required.

## Dependencies

None.

## Test plan

- Persistence: card-query tests + the set-equality tests (step 2),
  `make test-persistence`.
- Snapshots: one genre card and one composer card (placeholder variant
  covers the no-art case), light + dark, `make test-ui`.
- Source-convention tests: `@AppStorage("genres.viewMode")` and
  `@AppStorage("composers.viewMode")` present; each view presents the
  segmented `Picker`; the file split kept the #349 scroll-restore
  conventions intact.
- `make generate` if test files were added; full gates after.

## Acceptance criteria

- [ ] Genres and Composers each toggle List / Grid, persisted independently;
      defaults unchanged.
- [ ] Card sets are provably identical to the list sets (tests from step 2).
- [ ] Counts match what the lists imply (album counts distinct, song counts
      exclude disabled tracks).
- [ ] Sort menu applies in both modes.
- [ ] All gates green; suggested commits: the pure split as
      `refactor(ui): split GenresComposersView into per-view files`, then
      `feat(ui): add card-grid view mode to Genres and Composers (#363)`.

## Gotchas

- Genre and composer are free-text track columns; the same album can appear
  under many genres. That is correct, not a bug; its cover may appear in
  several genre mosaics.
- Case sensitivity: the list mode's distinct-genre behaviour is the source
  of truth. Do not introduce case folding the list does not have, or the
  set-equality test will (correctly) fail.
- The split in step 3 must be its own commit so `git blame` survives.

## Handoff

23-3 expects: all three sections have working, persisted grid modes; the
toggle pattern is identical in all three views (it will mirror them in the
View menu); nothing in `App/` has been touched yet.
