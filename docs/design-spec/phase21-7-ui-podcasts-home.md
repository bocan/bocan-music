# Phase 21-7: Podcasts UI - Sidebar item, subscribed grid, Add bar, UI seams

> Depends on: `phase21-0-overview.md`, `phase21-1-persistence.md` (read models),
> `phase21-4-subscriptions.md` (the `PodcastService` the App wires behind the
> seams). Touches **UI** and **App**. This is the entry point: the sidebar item,
> the subscribed-shows grid (album-grid styled), the always-present Add bar, and
> the UI-side protocol seams the App implements (so UI never imports `Podcasts`).
>
> Provides: `SidebarDestination.podcasts` + `.podcastShow(Int64)`,
> `PodcastsHomeView`, `PodcastsViewModel`, and the `PodcastLibraryDataSource` /
> `PodcastActions` protocols.

## Goal

A **Podcasts** row under **Local Library** that opens a window with an Add bar on
top and a grid of subscribed shows below, each shown like an album (artwork +
title + author). Clicking a show navigates to its episode list (phase 21-9).

## Why UI declares protocols (do not `import Podcasts` in UI)

The `UI` module must not import `Podcasts` (same rule as `Subsonic`: see the UI
CLAUDE.md and `SubsonicBrowseDataSource`). UI declares the protocols it needs;
the App layer conforms `PodcastService` (+ search service) to them and injects.

```swift
// UI module - the seams (App implements over PodcastService / PodcastSearchService).
public protocol PodcastLibraryDataSource: Sendable {
    func subscribedPodcasts() async throws -> [Podcast]
    func episodes(podcastID: Int64) async throws -> [EpisodeListItem]
    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
    func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>
}

public protocol PodcastActions: Sendable {
    @discardableResult func subscribe(feedURL: URL) async throws -> Int64
    func unsubscribe(podcastID: Int64) async throws
    func refresh(podcastID: Int64) async throws
    func refreshAll() async
    func reorder(podcastIDs: [Int64]) async throws
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws
    // Episode-level actions used by 21-9; declared here so the seam is one type.
    func play(episode: EpisodeListItem, podcast: Podcast) async
    func markPlayed(podcastID: Int64, guid: String) async
    func markUnplayed(podcastID: Int64, guid: String) async
    func download(podcastID: Int64, guid: String) async         // no-op if 21-6 not built
    func removeDownload(podcastID: Int64, guid: String) async
}
```

`Podcast` and `EpisodeListItem` come from `Persistence`, which UI already
imports, so the seam types are shareable without a `Podcasts` import. The search
seam is declared in phase 21-8 (`PodcastSearchProviding`); keep it separate so
search and library can be implemented independently.

`play(episode:podcast:)` lives in the App implementation because it must build
the podcast `QueueItem` (per the field contract in phase 21-5) and hand it to
`QueuePlayer`. The App has both the player and the data; UI only fires the
action.

## SidebarDestination additions

`Modules/UI/Sources/UI/SidebarDestination.swift`. Add two cases under a new
`// MARK: - Phase 21 (Podcasts)` section. **Do not** confuse these with the
existing `.subsonicPodcasts(UUID)` (that is a remote Subsonic server's podcasts);
these are the local feed library.

```swift
    // MARK: - Phase 21 (Podcasts)

    /// The local Podcasts library root: Add bar + subscribed-shows grid.
    case podcasts
    /// A subscribed show's episode list. Associated value is podcasts.id.
    case podcastShow(Int64)
```

`SidebarDestination` is `Codable` and persisted in `UIStateV1`; adding cases is
backward compatible for decode (old blobs never contained them). No migration is
required for additive enum cases here, but verify the persisted-UI-state decoder
tolerates unknown/new cases (it must already, given the Subsonic additions).

## Sidebar row

In `Modules/UI/Sources/UI/AppRoot/Sidebar.swift`, add a Podcasts row to the
**Local Library** section, after `Composers`, mirroring the existing
`sidebarRow(...)` calls:

```swift
self.sidebarRow(.podcasts,
                symbol: "antenna.radiowaves.left.and.right",
                label: L10n.string("Podcasts"))
```

(Choose the SF Symbol to match the app's visual language; `mic.fill`,
`waveform`, or `antenna.radiowaves.left.and.right` are all reasonable. Confirm it
reads well at sidebar size in light + dark.) Add the `L10n` key "Podcasts" and
run `make pseudolocale`.

`.podcastShow(id)` is a drill-down destination reached by clicking a grid cell,
not a sidebar row, so it needs no sidebar entry (like `.album(id)`).

## LibraryViewModel wiring

`LibraryViewModel` is the spine. Add a child view model and the seam injection,
mirroring how the Subsonic data source is held:

```swift
public let podcasts: PodcastsViewModel
// injected seams (nil-safe; podcasts feature can be absent in a stripped build)
public let podcastLibrary: (any PodcastLibraryDataSource)?
public let podcastActions: (any PodcastActions)?
```

Construct `PodcastsViewModel(library: podcastLibrary, actions: podcastActions)`
in `LibraryViewModel.init`. In the navigation extension
(`LibraryViewModel+Navigation.swift`), handle the new destinations in
`loadDestination`:

```swift
case .podcasts:
    await self.podcasts.loadSubscribed()
case let .podcastShow(id):
    await self.podcasts.loadShow(id)
```

## `PodcastsViewModel`

`@MainActor`, `@Observable` (or `ObservableObject` to match neighbouring view
models; follow the file you are editing). Owns the home grid + the current show.

```swift
@MainActor
public final class PodcastsViewModel: ObservableObject {
    @Published public private(set) var subscribed: [Podcast] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var currentShow: Podcast?
    @Published public private(set) var episodes: [EpisodeListItem] = []     // for the open show (phase 21-9)
    @Published public var addBarText = ""

    public init(library: (any PodcastLibraryDataSource)?, actions: (any PodcastActions)?)

    public func loadSubscribed() async                 // fetch + start observeSubscribed
    public func loadShow(_ id: Int64) async            // fetch show + start observeEpisodes
    public func refreshAll() async
    public func unsubscribe(_ id: Int64) async
    public func openShow(_ id: Int64)                  // -> library.selectDestination(.podcastShow(id))
}
```

`loadSubscribed` should both fetch once and start a `Task` consuming
`observeSubscribed()` so the grid updates live when a subscribe/unsubscribe/
refresh lands (use the `nonisolated(unsafe)` task-handle pattern the other view
models use; see the UI CLAUDE.md note about that warning).

## `PodcastsHomeView`

Routed from `ContentPane` for `.podcasts`. Structure: a persistent Add bar
docked at the top, the grid filling the rest.

```swift
public struct PodcastsHomeView: View {
    @ObservedObject var vm: PodcastsViewModel
    var library: LibraryViewModel

    public var body: some View {
        VStack(spacing: 0) {
            PodcastAddBar(vm: vm, library: library)        // phase 21-8 owns the search/detail behind it
            Divider()
            Group {
                if vm.subscribed.isEmpty {
                    PodcastsEmptyState()                    // "Subscribe to a podcast to get started"
                } else {
                    PodcastsGridView(vm: vm, library: library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.string("Podcasts"))
    }
}
```

### `PodcastAddBar` (the always-present add affordance)

A slim bar with a search field and an "Add by URL" affordance. Its job here is to
host the control and own the text; the search results popover/sheet and the
add-by-URL parsing are phase 21-8 (which reads `vm.addBarText` and presents
results). Keep the bar itself minimal:

- A `TextField` bound to `vm.addBarText`, prompt "Search podcasts or paste a feed
  URL".
- A magnifying-glass leading icon; a clear button when non-empty.
- Submit (Return) and live typing both drive search (debounced in 21-8).
- When the text parses as an http(s) URL, 21-8 shows an "Add this feed" row at the
  top of the results.

Phase 21-8 attaches the results presentation to this bar (a `.popover` or an
overlay results list). This slice ships the bar with the text binding and the
empty/placeholder results container so 21-8 can fill it.

### `PodcastsGridView` (subscribed shows, album-styled)

Reuse the album grid look (`AlbumsGridView` is the reference): a `LazyVGrid` of
adaptive cells, each cell `Artwork(artPath:)` (the cached `artwork_path` from the
podcast row) + title + author + an episode-count or "N new" subtitle. Clicking a
cell calls `vm.openShow(podcast.id)` which sets
`library.selectDestination(.podcastShow(id))`.

```swift
private struct PodcastCell: View {
    let podcast: Podcast
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(artPath: podcast.artworkPath, seed: Int(podcast.id ?? 0))
                .accessibilityLabel(L10n.string("\(podcast.title) artwork"))
            Text(podcast.title).font(Typography.subheadline).lineLimit(1)        // feed content - not localized
            Text(podcast.author ?? "").font(Typography.caption)
                .foregroundStyle(Color.textSecondary).lineLimit(1)              // feed content - not localized
        }
    }
}
```

Context menu on a cell: **Refresh**, **Mark all as played**, **Settings…** (auto
download toggle), **Unsubscribe…** (confirm, with the data-loss wording from
phase 21-4's unsubscribe decision). Drag-to-reorder maps to
`actions.reorder(podcastIDs:)` (optional; can be a later polish).

## ContentPane routing

`Modules/UI/Sources/UI/AppRoot/ContentPane.swift`, in the
`selectedDestination` switch:

```swift
case .podcasts:
    PodcastsHomeView(vm: self.vm.podcasts, library: self.vm)
case let .podcastShow(id):
    PodcastShowView(vm: self.vm.podcasts, library: self.vm, podcastID: id)   // phase 21-9
```

(`PodcastShowView` is a stub here that 21-9 fills; ship a minimal placeholder so
this slice compiles and navigates.)

## App-layer wiring

In `App`, conform `PodcastService` to `PodcastLibraryDataSource` and build a
`PodcastActions` adapter that holds `PodcastService` + the `QueuePlayer` (for
`play`) + the download manager (for `download`/`removeDownload`, no-ops if phase
21-6 is not built). Inject both into `LibraryViewModel`. Start the
`FeedRefreshScheduler` (phase 21-4) after launch.

```swift
extension PodcastService: PodcastLibraryDataSource {}   // method names already match

struct AppPodcastActions: PodcastActions {
    let service: PodcastService
    let player: QueuePlayer
    let downloads: EpisodeDownloadManager?      // phase 21-6; nil otherwise
    // subscribe/unsubscribe/refresh/... forward to service
    // play(episode:podcast:) builds the podcast QueueItem (phase 21-5 contract) and calls player
}
```

## Context7 lookups

- None strictly required; this is SwiftUI over existing patterns. If unsure about
  `LazyVGrid` adaptive sizing parity with `AlbumsGridView`, read that file rather
  than Context7.

## Test plan

`Modules/UI/Tests/UITests/` (and ViewModelTests for the Xcode bundle - remember
`make generate` after adding a ViewModelTests file, per the UI CLAUDE.md):

- **PodcastsViewModel** (with a stub `PodcastLibraryDataSource` / `PodcastActions`):
  `loadSubscribed` populates `subscribed` and reflects an observation update;
  `openShow` sets the destination; `unsubscribe` calls the action.
- **Source-convention test** for `Sidebar.swift`: the Podcasts row exists under
  Local Library and routes to `.podcasts` (read the source via `#filePath` and
  assert, the established host-less UI test pattern).
- **Snapshot tests** (`make test-ui`) for `PodcastsHomeView` empty state and a
  populated grid (stub data), light + dark.
- **L10n**: the new keys ("Podcasts", Add bar prompt, empty-state copy, context
  menu items) exist in the catalog with `en-XA` variants (run `make
  pseudolocale`); `L10nTests` passes.

## Acceptance criteria

- [ ] A **Podcasts** row appears under **Local Library** and opens
      `PodcastsHomeView`.
- [ ] The Add bar is always visible at the top of the Podcasts window.
- [ ] Subscribed shows render as an album-styled grid (cached artwork, title,
      author); clicking a show navigates to `.podcastShow(id)`.
- [ ] UI does not import `Podcasts`; everything goes through
      `PodcastLibraryDataSource` / `PodcastActions`, implemented in App.
- [ ] Empty state shown when there are no subscriptions; grid updates live via the
      subscription observation.
- [ ] All new copy is localized; `make pseudolocale` run; `L10nTests` green.
- [ ] `make test-ui` green; no SwiftLint (incl. the 500-line `file_length`) or
      SwiftFormat warnings.

## Gotchas

- **Two "Podcasts" in the sidebar.** Local `.podcasts` lives under Local Library;
  the remote `.subsonicPodcasts(serverID)` lives under a Subsonic server. They
  are different features and must not be merged or cross-wired.
- **No `import Podcasts` / `import Subsonic` in UI.** Use the seam protocols. The
  seam types (`Podcast`, `EpisodeListItem`) come from `Persistence`, which UI
  already imports.
- **`file_length` 500-line cap.** `Sidebar.swift` and `ContentPane.swift` are
  large; adding cases may push them over. Factor the podcast home/grid into their
  own files (as above) rather than swelling existing ones, and do not add a
  `swiftlint:disable`.
- **Feed content is not localized.** Show titles, authors, episode titles render
  verbatim. Only chrome routes through `L10n`. The cell comments above flag this.
- **High-frequency observation + menu bar.** Per the UI CLAUDE.md, do not let a
  hot observation invalidate `App/BocanCommands`. The podcasts grid observation is
  low-frequency (subscribe/refresh), so fine; just keep the menu commands taking
  the view models as plain `let`.

## Handoff

Phase 21-8 fills the Add bar with live search results (source badges) and the
detail + Subscribe flow. Phase 21-9 fills `PodcastShowView` with the episode
table and reads `vm.episodes`. Phase 21-10 adds the podcast Now-Playing rendering
and the settings pane (auto-download, refresh interval, storage).
