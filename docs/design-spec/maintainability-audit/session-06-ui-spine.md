# Session 6: UI spine

> Read [README.md](README.md) first. Scope + starting points only. This is the
> first of four `UI` sessions -- one scope per session, triage fully, stop.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Sources/UI/ViewModels` | 13 | ~4.5k | `LibraryViewModel` spine + siblings. |
| `Sources/UI/AppRoot` | 9 | ~2.3k | `BocanRootView`, `Sidebar`, `ContentPane`. |
| `Sources/UI/Common` | 13 | ~1.4k | Reusable views (`EmptyState`, `LoadingState`, `Artwork`, ...). |
| `Sources/UI/Theme` | 9 | ~0.8k | Colours, typography, a11y modifiers. |
| `Sources/UI/{Utility,Accessibility,Components,Localization}` + top-level files | ~7 | ~1.0k | Helpers, the Phase 23 `Components/`. |

Prereq: Sessions 1 to 5. Gate: `make test-ui` (plus `make test-coverage` for the
view-model tests globbed into the Xcode bundle; `make generate` if test files
are added).

## Start here (seeded candidates)

- **View-model `load()` patterns.** Several view models repeat
  `isLoading = true; async let ...; assign; isLoading = false`. Compare
  `AlbumsViewModel` / `ArtistsViewModel` / tracks / podcasts loaders (Phase 23
  already touched some). A shared "load with loading flag" helper may pay off --
  measure; this can easily be over-abstracted.
- **`@Published` + persisted-preference plumbing.** The sort-order pattern
  (`@AppStorage` or UserDefaults-backed enum + `setSortOrder`) recurs. Confirm
  `SortMenu` + `SortMenuOption` already carry it and nothing re-implements it.
- **Common views.** Check `EmptyState`/`LoadingState`/`ErrorState` are the single
  source for those states and views are not hand-rolling equivalents (Browse in
  Session 7 will be checked against these).
- **Scroll-restore (#349) pattern.** The offset-snapshot + restore appears in the
  albums grid, artists, and the Phase 23 collection grids. It is already partly
  shared via `CollectionCardGrid`; check the remaining hand-rolled copies for a
  common modifier.
- **Confirm the Phase 23 `Components/`** (`CollectionCard`, `CollectionCardGrid`,
  `CollectionModeToggle`, `CollectionListRow`, `CoverMosaicGenerator`) are used
  everywhere they should be and not shadowed by older inline copies.

## Exit criteria

- The spine scope triaged; ledger rows for all clusters.
- Reusable UI helpers recorded in the shared-surface table for Sessions 7 to 9.
- `make test-ui`, `make lint`, `make build`, `make test-coverage` green.
