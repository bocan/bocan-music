# Phase 23: Collection Browsing Grids - Overview and Cross-Slice Contract

> Prerequisites: Phases 0 to 22 complete. The module DAG, the GRDB `Database`
> actor + repository pattern, `AlbumsGridView` (Phase 4), the playlist mosaic
> generator (Phase 6), the `L10n` localization workflow (#314), and the
> per-view `@AppStorage` sort preferences (`genres.sortOrder`,
> `composers.sortOrder`) all exist.
>
> Read `docs/design-spec/_standards.md` first, then this file. **This file is
> the contract.** Slices 23-1 through 23-3 each implement one piece of it; read
> this overview before starting any of them so the shared types, preference
> keys, query shapes, and UI conventions line up.
>
> Origin: GitHub issue #363 (lukesutton). Target release: 2.3.0.

## What this is

The Artists, Genres, and Composers views are plain text lists today. This
phase gives each of them a second, visual browsing mode: an adaptive grid of
"collection cards", each showing a composite 2x2 mosaic of that collection's
album covers, the collection name, and an "N albums · M songs" subtitle. A
toggle next to the existing sort button switches between List and Grid, the
View menu mirrors the same choice, and the selection persists per section so
each view stays the way the user left it.

A second, smaller piece (slice 23-3) addresses the ticket author's literal
request: after clicking a genre or composer, the destination currently shows a
flat track list. It gains a Songs / Albums switch so the destination can show
that genre's or composer's albums as a grid instead, also persisted per
section.

## Why 2x2 and not 6 or 8 covers

Mosaics tile cleanly only at perfect squares (1, 4, 9). The existing
`PlaylistMosaicGenerator` already composites up to four covers into a 2x2
square and is cached and off-main-thread. Reuse beats invention: 2x2 is the
established look (iTunes, Spotify), reads clearly at card size, and most
artists have fewer than nine albums anyway. One album renders as a single
full-bleed cover. Zero albums renders a placeholder symbol tile.

## Shared contract (all slices)

### View-mode type and preference keys

One shared enum in the UI module, file
`Modules/UI/Sources/UI/Browse/CollectionViewMode.swift`:

```swift
/// How a collection listing (Artists, Genres, Composers) renders.
public enum CollectionViewMode: String, CaseIterable, Sendable {
    case list
    case grid
}
```

Persisted with `@AppStorage`, matching the `genres.sortOrder` precedent:

| Key                     | Type                 | Default | Slice |
|-------------------------|----------------------|---------|-------|
| `artists.viewMode`      | `CollectionViewMode` | `.list` | 23-1  |
| `genres.viewMode`       | `CollectionViewMode` | `.list` | 23-2  |
| `composers.viewMode`    | `CollectionViewMode` | `.list` | 23-2  |
| `genres.detailMode`     | `CollectionDetailMode` (`songs` / `albums`) | `.songs` | 23-3 |
| `composers.detailMode`  | `CollectionDetailMode`                      | `.songs` | 23-3 |

Defaults preserve today's behaviour exactly. Raw-representable string enums so
`@AppStorage` handles them directly.

### The mosaic engine

Generalize `Modules/UI/Sources/UI/Playlists/PlaylistMosaicGenerator.swift`
into a shared `CoverMosaicGenerator` (same directory move is allowed; suggest
`Modules/UI/Sources/UI/Components/CoverMosaicGenerator.swift`):

- Keep the existing actor + cache + `compose(images:sideLength:)` logic
  byte-for-byte where possible; this is a rename and a key generalization, not
  a rewrite.
- API: `func mosaic(paths: [String], version: Int64, sideLength: Int = 144) -> NSImage?`.
- Playlist call sites migrate and pass `version: updatedAt` (unchanged
  behaviour). Collection cards pass `version: 0`: cover-art paths are
  content-addressed by hash (see `CoverArtCache`), so any art change changes
  the path list and therefore the cache key. Membership changes also change
  the path list. No separate version signal is needed.
- Add a cache cap: when the cache exceeds 512 entries, clear it (`removeAll`).
  Playlists never hit this; a large artist grid could. A simple clear is fine;
  do not build an LRU.
- Unit tests: compose with 1, 2, 3, 4 input images produces a square image;
  cache returns the identical instance on a second call; the cap clears.

### The card and grid components

Two new shared views in `Modules/UI/Sources/UI/Components/`:

- `CollectionCard.swift`: mosaic (or placeholder symbol tile), name
  (`Typography.body`, primary), subtitle (`Typography.caption`, secondary).
  Placeholder symbols: `music.mic` (artists), `tag` (genres),
  `music.quarternote.3` (composers), passed in by the host view.
- `CollectionCardGrid.swift`: adaptive `LazyVGrid` mirroring
  `AlbumsGridView` metrics exactly: `@ScaledMetric` on
  `Theme.albumGridMinWidth`, spacing `Theme.albumGridSpacing`. Takes an array
  of card models plus `onOpen` and an optional per-card context menu builder.

Card model (UI-layer struct, not persisted):

```swift
struct CollectionCardModel: Identifiable, Hashable {
    let id: String            // artist DB id as string, or the genre/composer name
    let title: String
    let albumCount: Int
    let songCount: Int
    let coverArtPaths: [String]   // up to 4, deterministic order
}
```

Accessibility contract (matches the list rows being replaced):

- Each card is one accessibility element (`.accessibilityElement(children: .combine)`).
- Label: the collection name. Value: the localized "N albums, M songs" text.
- Hint: localized "Opens this artist's albums and songs" (per-section variant).
- Mosaic and placeholder are `.accessibilityHidden(true)`.

Subtitle copy reuses the existing catalog keys from the artist list rows:
`"\(albumCount) albums"`, `"\(trackCount) songs"`, joined with `" · "` the way
`SmartPlaylistDetailView.subtitle` joins its parts. Any new keys go through
`L10n` + `Localizable.xcstrings` + `make pseudolocale` (see
`docs/design-spec/localization.md`).

### Persistence queries

New extension file
`Modules/Persistence/Sources/Persistence/Repositories/AlbumRepository+CollectionCards.swift`
(a new file, because `AlbumRepository.swift` is near the 500-line lint
ceiling). All queries exclude disabled tracks (`tracks.disabled = 0`),
consistent with `fetchTrackCounts`.

```swift
public struct CollectionCardData: Sendable, Hashable {
    public let name: String
    public let albumCount: Int
    public let songCount: Int
    public let coverArtPaths: [String]   // up to maxCovers, deterministic
}

extension AlbumRepository {
    /// Cover-art paths per album-artist id, up to `maxPerArtist` each,
    /// ordered by album year DESC then title (deterministic).
    public func fetchCoverArtPathsByAlbumArtist(maxPerArtist: Int = 4)
        async throws -> [Int64: [String]]

    /// One row per distinct non-empty genre, with counts and cover paths.
    public func fetchGenreCards(maxCovers: Int = 4)
        async throws -> [CollectionCardData]

    /// One row per distinct non-empty composer, same shape.
    public func fetchComposerCards(maxCovers: Int = 4)
        async throws -> [CollectionCardData]
}
```

Query sketches (adjust to GRDB idiom, keep the semantics):

- Artist covers: `SELECT album_artist_id, cover_art_path FROM albums WHERE
  cover_art_path IS NOT NULL AND album_artist_id IS NOT NULL ORDER BY year
  DESC, title` then group client-side, `prefix(maxPerArtist)`.
- Genre cards: join `tracks` (disabled = 0, genre non-empty) to `albums` on
  `album_id`; counts are `COUNT(DISTINCT album_id)` and `COUNT(*)` grouped by
  genre; cover paths from the joined albums, deduped, deterministic order,
  client-side prefix. Composers identical on `tracks.composer`.

**Set-equality requirement**: the set of genres (and composers) produced by
`fetchGenreCards` must equal the set the existing list mode shows (the
`TrackRepository` fetch used by `GenresView` today). Both modes must always
show the same collections. Write a persistence test that asserts this against
a seeded database including edge rows (empty-string genre, disabled track,
compilation album with nil album artist).

### Interaction contract

- Card click navigates exactly like the list row it replaces:
  `library.selectDestination(.artist(id))`, `.genre(name)`, `.composer(name)`.
- Artists grid keeps the list's context menu ("Remove Artist from Library").
  Genres/composers lists have no context menu today; the grids add none.
- The existing `SortMenu` applies to both modes: the grid is ordered by the
  same sorted array the list renders.
- Scroll restore: follow the established pattern (#349): snapshot the visited
  item (`lastVisitedArtistID`, `lastVisitedGenre`, ...) and re-center it when
  the grid rebuilds on return, mirroring `AlbumsGridView`'s
  `ScrollPosition`-based restore. Do not regress list-mode restore.
- The toggle is a two-segment `Picker` (`.pickerStyle(.segmented)`) with
  `list.bullet` and `square.grid.2x2` icons, placed in the toolbar row next to
  `SortMenu`, with localized `help` and accessibility labels.

## Slices

| Slice | File | Delivers |
|-------|------|----------|
| 23-1 | [phase23-1-artists-grid.md](phase23-1-artists-grid.md) | Shared infrastructure (`CollectionViewMode`, `CoverMosaicGenerator`, card + grid components, artist cover query) and the Artists grid mode with toggle + persistence |
| 23-2 | [phase23-2-genres-composers-grid.md](phase23-2-genres-composers-grid.md) | Genre + composer card queries and grid modes; splits `GenresComposersView.swift` if the lint ceiling requires |
| 23-3 | [phase23-3-view-menu-destination-albums.md](phase23-3-view-menu-destination-albums.md) | View-menu integration; Songs / Albums destination switch for genre and composer detail; README + website docs |

Each slice ends gates-green and is committed on its own (Conventional Commits,
scope `ui` or `persistence` as appropriate). Do not start a slice with the
previous one uncommitted.

## Non-goals

- No album-grid mode for Recently Added / Recently Played / Most Played smart
  folders. The ticket's "any listing" arguably covers them, but they are
  track-recency concepts and "recently added albums" is a different feature.
  Note it as a possible follow-up in the 23-3 handoff; do not build it.
- No per-item persistence (e.g. per-genre detail mode). Persistence is per
  section, as the ticket requests.
- No changes to Subsonic browse views; local library only.
- No user-editable collection artwork. Mosaics are derived, never stored in
  the database.
- No new sort options; the existing `SortMenu` choices apply unchanged.

## Gotchas (named in advance)

- **`GenresComposersView.swift` and `App/BocanCommands.swift` sit near the
  500-line SwiftLint ceiling.** Splitting `GenresView` and `ComposersView`
  into their own files is the sanctioned fix for the former; for the latter,
  extract a command group into an extension file. Never add a
  `swiftlint:disable`.
- **Menu-bar invalidation**: `BocanCommands` takes view models as plain `let`
  on purpose (root `CLAUDE.md`). The View-menu items must not introduce
  observation of high-frequency view models; read state when the menu opens.
- **`App/` has no String Catalog.** Existing menu titles in `BocanCommands`
  are grandfathered bare literals; slice 23-3 follows that file's existing
  convention for the two new items and goes no further. Menu-bar localization
  is a known pre-existing gap; do not try to solve it inside this phase.
- **Snapshot tests only run under `make test-ui`** (SPM package). New files in
  `Modules/UI/Tests/UITests/ViewModelTests/` are also globbed by the Xcode
  bundle, which requires `make generate` before `make test` / `make
  test-coverage` sees them.
- **`Localizable.xcstrings` churn**: after adding keys run `make pseudolocale`
  or the en-XA coverage test fails; an Xcode build may rewrite the catalog
  with unrelated churn (see repo memory), which `make pseudolocale`
  renormalizes.
- **`AlbumInteractiveCell` in `AlbumsGridView.swift` is private.** Do not
  reach for it; `CollectionCardGrid` implements its own minimal open-on-click
  handling. Keyboard parity with the albums grid (arrow keys) is a
  nice-to-have, not a requirement, in this phase.
- **Artists with no albums as album-artist** (e.g. an artist who only appears
  on compilations) legitimately show "0 albums, N songs" with a placeholder
  tile. The list shows them today; the grid must too.

## Acceptance criteria (phase level)

- [ ] Artists, Genres, and Composers each offer List and Grid modes; the
      toggle sits next to the sort button; the View menu mirrors it.
- [ ] Each section remembers its mode across launches independently.
- [ ] Cards show a 2x2 mosaic (or single cover, or placeholder), name, and
      localized album/song counts; VoiceOver reads each card as one element.
- [ ] Genre and composer destinations offer Songs / Albums, persisted.
- [ ] List mode is pixel-unchanged when grid mode is off (default).
- [ ] All gates green per slice: `make format`, `make lint`, `make build`,
      `make test-coverage`, `make test-ui`, `make test-persistence`,
      `make pseudolocale` when the catalog changed.
- [ ] README + website updated (slice 23-3). Issue #363 closed by the release.
