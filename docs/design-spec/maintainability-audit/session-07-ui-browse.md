# Session 7: UI Browse

> Read [README.md](README.md) first. Scope + starting points only. The single
> largest scope in the audit -- keep it to one session, do not spill.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Sources/UI/Browse` (incl. `Browse/Subsonic`, `Browse/Podcasts`) | 74 | ~13k | Tracks/Albums/Artists/Genres/Composers, the track table stack, Subsonic browse views, queue. |

Prereq: Sessions 1 to 6 (dedup against the UI spine's shared surface). Gate:
`make test-ui`, `make test-coverage`.

## Start here (seeded candidates)

- **Subsonic browse views (high-value).** `SubsonicSongsView`, `SubsonicAlbumsView`,
  `SubsonicArtistsView`, `SubsonicGenresView`, `SubsonicPlaylistsView`,
  `SubsonicStarredView`, `SubsonicBookmarksView`, ... are a large parallel-view
  family, each with load + empty + list + toolbar. Normalized-diff several; this
  is the biggest single dedup opportunity in the module. Apply the coupling and
  config-bag tests hard -- the Phase 23 lesson (a generic engine was *rejected*
  for the genre/composer twins) applies directly. Prefer sharing config-free
  leaves (rows, empty states, load helpers) over one mega-generic browse view.
- **The track table stack.** `TrackTable`, `TrackTable+ColSpecs`, `+Helpers`,
  `TrackTableCoordinator`, `TrackTableHelpers`, `ContextMenuTableView` -- already
  split for line length; check for logic duplicated *between* the local track
  table and the Subsonic song table coordinator.
- **Local vs Subsonic parallelism.** `ArtistsView` vs `SubsonicArtistsView`,
  `AlbumsGridView` vs `SubsonicAlbumsView` -- do local and remote variants share
  cell/row rendering, or hand-roll near-identical cells? Share the cell, keep the
  data source distinct.
- **Album/artist cells.** After Phase 23, confirm `CollectionCard` and the album
  cells are not shadowed by older inline cell copies.
- **Empty/loading/error states.** Verify Browse uses the `Common` states
  (Session 6) rather than bespoke ones.

## Exit criteria

- Browse fully triaged; ledger rows for all clusters, especially the Subsonic
  browse-view family (with the explicit share-leaves-not-trunk decision).
- `make test-ui`, `make test-coverage`, `make lint`, `make build` green.
