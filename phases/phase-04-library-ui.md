# Phase 4 — Library UI

> Prerequisites: Phases 0–3 complete. A populated DB and working scanner.
>
> Read `phases/_standards.md` first.

## Goal

Build the three-pane browser (sidebar | content | now-playing strip) so you can navigate and search your library, multi-select tracks, and trigger playback. **No queue or gapless logic yet** — clicking a track starts playback of that single track via the Phase 1 `AudioEngine`. Queue lands in Phase 5.

## Non-goals

- Queue management, next/previous — Phase 5.
- Playlists sidebar section beyond a placeholder — Phase 6.
- Smart playlists — Phase 7.
- Tag editor — Phase 8.
- Mini player — Phase 10.
- Visualizers — Phase 12.

## Outcome shape

```
Modules/UI/
├── Package.swift
├── Sources/UI/
│   ├── AppRoot/
│   │   ├── RootView.swift                 # NavigationSplitView
│   │   ├── Sidebar.swift
│   │   ├── ContentPane.swift              # Router based on Sidebar selection
│   │   └── NowPlayingStrip.swift
│   ├── Browse/
│   │   ├── TracksView.swift               # Table
│   │   ├── AlbumsGridView.swift
│   │   ├── ArtistsView.swift
│   │   ├── GenresView.swift
│   │   ├── ComposersView.swift
│   │   ├── AlbumDetailView.swift
│   │   ├── ArtistDetailView.swift
│   │   └── SmartFolders.swift             # Recently Added/Played, Most Played
│   ├── Search/
│   │   ├── SearchField.swift
│   │   └── SearchResultsView.swift
│   ├── Common/
│   │   ├── Artwork.swift                  # Async image loader + cache
│   │   ├── ContextMenus.swift             # Reusable menu builders
│   │   ├── Formatters.swift               # Duration, bitrate, etc.
│   │   ├── KeyBindings.swift              # Centralised shortcuts
│   │   └── EmptyState.swift
│   ├── ViewModels/
│   │   ├── LibraryViewModel.swift
│   │   ├── TracksViewModel.swift
│   │   ├── AlbumsViewModel.swift
│   │   ├── ArtistsViewModel.swift
│   │   ├── SearchViewModel.swift
│   │   └── NowPlayingViewModel.swift
│   ├── Theme/
│   │   ├── Theme.swift
│   │   ├── Colours.swift
│   │   └── Typography.swift
│   └── Accessibility/
│       └── A11yIdentifiers.swift
└── Tests/UITests/
    ├── SnapshotTests/
    │   ├── SidebarSnapshotTests.swift
    │   ├── TracksViewSnapshotTests.swift
    │   ├── AlbumsGridSnapshotTests.swift
    │   ├── AlbumDetailSnapshotTests.swift
    │   └── NowPlayingStripSnapshotTests.swift
    ├── ViewModelTests/
    │   ├── TracksViewModelTests.swift
    │   ├── AlbumsViewModelTests.swift
    │   ├── SearchViewModelTests.swift
    │   └── NowPlayingViewModelTests.swift
    ├── AccessibilityTests.swift
    └── __Snapshots__/...
UITests/                                    # Real XCUITest target (root)
└── LibraryUITests.swift
```

## Implementation plan

1. **`UI` module** Swift Package. Depends on `Observability`, `Persistence`, `AudioEngine`. Does **not** (yet) depend on anything queue-related.
2. **`RootView`** — `NavigationSplitView` with sidebar / content / (conditionally) detail. Full-height bottom overlay is the `NowPlayingStrip`.
3. **`Sidebar`** — sections:
   - **Library**: Songs, Albums, Artists, Genres, Composers.
   - **Recents**: Recently Added, Recently Played, Most Played.
   - **Playlists**: empty placeholder section (Phase 6 populates).
   - Selection is an enum `SidebarDestination: Hashable` that `ContentPane` switches on.
4. **`TracksView`** — `Table<TrackRow>` with columns: `#`, Title, Artist, Album, Year, Genre, Duration, Plays, Rating, Added.
   - Columns sortable, user-reorderable, visibility toggled via the context menu on the header; persisted to `settings`.
   - Row height follows `Theme.rowHeight`, fits ≥ 32 rows on screen at default size.
   - Selection is `Set<Track.ID>`.
   - Double-click or `Return` plays the track. `Space` toggles play/pause.
   - Right-click → context menu.
5. **`AlbumsGridView`** — `LazyVGrid` with `GridItem(.adaptive(minimum: 180))`. Each cell: cover art + title + artist + (secondary) track count. Click → `AlbumDetailView` (pushed in the split view detail column). Cmd-click multi-select albums → context menu operations.
6. **`AlbumDetailView`** — header (large cover + metadata + play/shuffle buttons) + track list (same component as `TracksView` with the album/artist columns hidden).
7. **`ArtistsView`** — sidebar-style list of artists with count. Selecting one reveals albums (grid), then tracks on drilldown.
8. **`SmartFolders`** — pre-defined queries: Recently Added (last 30 days), Recently Played (90 days), Most Played (play_count DESC limit 100). Implemented as read-only views over `TrackRepository` queries.
9. **Global search** — `SearchField` in the toolbar. Drives `SearchViewModel` which debounces 250ms, hits the FTS tables, returns grouped results (Tracks / Albums / Artists). `⌘F` focuses the field.
10. **Context menus** — in a reusable builder:
    - Play Now
    - Play Next *(stubbed no-op, enabled in Phase 5)*
    - Add to Queue *(stubbed, Phase 5)*
    - Add to Playlist ▸ *(stub, Phase 6)*
    - Love / Unlove
    - Rate ▸ (0–5 stars)
    - Show in Finder
    - Get Info *(stub, Phase 8)*
    - Copy (track metadata as TSV)
11. **Keyboard shortcuts** — centralised in `KeyBindings` and bound via `CommandMenu`/`.keyboardShortcut(...)` on views:
    - `⌘F` focus search
    - `␣` play/pause (when not in a text field)
    - `⌘⇧N` new playlist (Phase 6 wires the action)
    - `⌘I` get info (Phase 8)
    - `⌘R` reveal in Finder
    - `⌘1…5` set rating
    - `⌘L` love
    - `⌥⌘→/←` drill into/out of content
12. **Drag and drop**:
    - Drag tracks out → pasteboard carries `(file URL, track metadata)`. Dropping on Finder copies the file (since we have read access via bookmark).
    - Dropping onto sidebar playlists is wired in Phase 6; use `DropDelegate` now but target an empty set of destinations.
13. **`Artwork`** view — loads a cover image from `CoverArtCache` path asynchronously, caches decoded `NSImage` in an `NSCache` keyed by hash, fades in. Placeholder: a deterministic gradient seeded by the album hash (so missing art still looks intentional).
14. **`NowPlayingStrip`** — small bar at the bottom (height ~72): artwork, title, artist, transport (prev/play-pause/next — prev/next disabled for now), scrubber with time labels, volume slider. Subscribes to `AudioEngine.state` and updates live.
15. **Theme** — define semantic colours (`accent`, `bgPrimary`, `bgSecondary`, `textPrimary`, `textSecondary`, `textTertiary`, `separator`, `ratingFill`, `lovedTint`). Tokens live in `Colours.swift` and resolve via `Color("...", bundle: .module)` from `Assets.xcassets` with explicit light/dark pairs.
16. **Accessibility**:
    - Every image has an `accessibilityLabel` (cover art uses `"<album> by <artist>"`).
    - Every button has a label. The transport strip uses `accessibilityAction(named:)` for VoiceOver rotor.
    - Focus order tested manually with full keyboard access on.
    - Respect `accessibilityReduceMotion` for fade-ins.
    - Dynamic type: use `.font(.body)` / `.font(.headline)` rather than fixed pt sizes.
17. **Localization** — all strings via String Catalog `Localizable.xcstrings` in the `UI` module bundle. Even if only `en` for v1.
18. **Persistence of UI state** — sidebar width, column visibility, column order, sort, last-selected destination: all serialised as JSON into a single `settings` key `ui.state.v1`. Restored on launch.
19. **Window chrome** — `.windowStyle(.titleBar)`, `.windowResizability(.contentSize)`, `.windowToolbarStyle(.unified)`. Save/restore window frame autosave-named `BocanMainWindow`.
20. **Performance**:
    - `LazyVStack`/`LazyVGrid` everywhere; never enumerate the whole library into a view.
    - Table backed by a paged query when > 5000 rows; otherwise direct fetch.
    - Artwork loader caps concurrent decodes (e.g. 6) and cancels off-screen.

## Definitions & contracts

### `SidebarDestination`

```swift
public enum SidebarDestination: Hashable, Sendable, Codable {
    case songs
    case albums
    case artists
    case genres
    case composers
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case artist(Int64)
    case album(Int64)
    case genre(String)
    case composer(String)
    case playlist(Int64)         // Phase 6+
    case smartPlaylist(Int64)    // Phase 7+
    case search(String)
}
```

### `NowPlayingViewModel`

```swift
@MainActor
public final class NowPlayingViewModel: ObservableObject {
    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public var volume: Float = 1.0
    public init(engine: Transport, database: Database)
    public func playPause() async
    public func scrub(to time: TimeInterval) async
    public func setVolume(_ v: Float) async
}
```

## Context7 lookups

- `use context7 SwiftUI NavigationSplitView macOS`
- `use context7 SwiftUI Table sortable columns resizable`
- `use context7 SwiftUI LazyVGrid performance large dataset`
- `use context7 SwiftUI drag drop Transferable`
- `use context7 SwiftUI focus keyboard shortcut`
- `use context7 swift-snapshot-testing SwiftUI macOS`
- `use context7 SwiftUI String Catalog Localizable.xcstrings`

## Dependencies

- `pointfreeco/swift-snapshot-testing` (test-only).
- No new runtime dependencies.

## Test plan

### ViewModel unit tests

- **`TracksViewModel`**: sort changes update the query; filter narrows results; selection works across multi-select operations (shift-range, cmd-toggle).
- **`AlbumsViewModel`**: grouping and ordering correct; drill-down produces the expected track list; empty library → empty state.
- **`SearchViewModel`**: debounces; cancels in-flight queries; handles unicode inputs.
- **`NowPlayingViewModel`**: reacts to engine state changes; scrubbing dispatches `seek`; volume clamped to [0, 1].

### Snapshot tests

For each of sidebar, tracks view, albums grid, album detail, search results, now-playing strip:

- Empty state (no tracks)
- Small dataset (5 items)
- Medium dataset (200 items) — table only
- Light + dark mode
- Default font size + `extraLarge` dynamic type
- With and without cover art

Run snapshots at a fixed window size (e.g. 1280×800) and via `@MainActor`. Commit PNGs; CI diffs.

### Accessibility tests

- Every view passes `Accessibility Inspector`'s audit when run on a hosted window.
- Every interactive element has a non-empty `accessibilityLabel`.
- Tab order hits every actionable element, no traps.

### UI (XCUITest) smoke tests

- Launch → window shows sidebar and an empty state.
- Scan a fixture library via a debug `⌘⇧T` menu (that imports a bundled fixture), then verify the Songs row count matches fixture size.
- Type in search, results appear in < 1s.
- Double-click a track, `NowPlayingStrip` updates within 500ms.
- Toggle sidebar collapse and restore.

## Acceptance criteria

- [ ] Navigation between Songs/Albums/Artists feels instant on a 10k-track library.
- [ ] Multi-select behaves like a macOS-native table (shift-range, cmd-toggle, arrow keys, select all).
- [ ] Search returns results in < 300ms on 10k tracks.
- [ ] Light and dark themes look deliberate on every screen.
- [ ] All views pass a snapshot test in both themes.
- [ ] Column visibility, order, sort and sidebar width persist across launches.
- [ ] Window restores its previous size and position.
- [ ] Double-click / `Return` plays a track via the engine; `Space` toggles.
- [ ] Every image/button has an accessibility label; keyboard-only navigation works end-to-end.
- [ ] 80%+ coverage on `Modules/UI` non-view code (views themselves count via snapshots).
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **`Table` virtualisation** in SwiftUI for macOS is decent but not perfect. If you hit jank past 5k rows, swap the backing source to a paginated query or drop to `NSTableView` via representable — but measure first.
- **`LazyVGrid` cover-art loading**: loading on appear is fine, but cancelling on disappear is essential — use `.task(id:)` with the item identity, and cancel through `Task` inheritance.
- **`Image` from `NSImage`**: SwiftUI caches internally but won't free under memory pressure. Route through an `NSCache` with a cost limit (bytes).
- **Sort persistence**: `KeyPathComparator` is not Codable. Encode the column identifier + direction as your own enum, reconstruct on load.
- **`NavigationSplitView` detail column** reappears weirdly on some macOS versions when swapping destinations. Use `navigationDestination(for:)` on the detail `NavigationStack`, not ad-hoc swapping.
- **Drag pasteboard**: to drag audio files out, register `kUTTypeFileURL` and provide the security-scoped URL's `path`. Finder will copy (it holds the scope via the pasteboard).
- **Dark mode contrast**: check secondary text against the secondary background; the default `.secondary` is often too faint in dark mode against `Color(nsColor: .underPageBackgroundColor)`.
- **Snapshots are flaky** across macOS minor versions. Pin the Xcode version in CI; record on the same version you run in CI.
- **String Catalog** requires Xcode 15+ indexing to populate; commit the `.xcstrings` file and let Xcode extract strings on build.
- **`⌘F` in a table**: SwiftUI's default table forwards `⌘F` to its own filter control if present. Provide an explicit focus state and intercept.
- **Reveal in Finder** from sandbox: use `NSWorkspace.shared.activateFileViewerSelecting([url])` — requires the security scope active.
- **Window restoration**: `NSWindow.FrameAutosaveName` is stored in user defaults, not the sandbox container on some macOS versions — verify on a clean account before shipping.
- **`⌘W`** must not terminate the app. Override the close behaviour to hide the window if mini-player mode is intended to survive (Phase 10 will finalise; stub the behaviour with a TODO).

## Handoff

Phase 5 (Queue) expects:

- `ContextMenus` has ready stubs for `Play Next` and `Add to Queue` that Phase 5 will wire.
- `NowPlayingViewModel` depends on a `Transport` protocol, not the concrete `AudioEngine` — Phase 5 will replace its engine with a `QueuePlayer` that conforms to `Transport`.
- Selection state is exposed as `Set<Track.ID>` so Phase 5 can build queues from selections.
- `TracksView` double-click and `Return` trigger an injected action, not a hardcoded "play this one file now" — making it trivial to replace with "enqueue and play".
