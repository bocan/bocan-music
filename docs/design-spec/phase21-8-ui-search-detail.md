# Phase 21-8: Podcasts UI - Search results (source badges), detail, Subscribe

> Depends on: `phase21-0-overview.md`, `phase21-3-search.md` (the search service),
> `phase21-2-feeds.md` (feed parsing for detail), `phase21-4-subscriptions.md`
> (subscribe), `phase21-7-ui-podcasts-home.md` (the Add bar that hosts this).
> Touches **UI** and **App** (the search seam implementation).
>
> Provides: live dual-index search results under the Add bar with a source
> badge per result; add-by-URL detection; the podcast detail view with a recent-
> episode preview and a Subscribe / Back affordance.

## Goal

Turn the Add bar (phase 21-7) into a working discovery surface: as the user
types, show merged Podcast Index + iTunes results with a small badge indicating
which index each came from; if the text is a feed URL, offer "Add this feed".
Clicking a result opens a detail view sourced from the feed (channel metadata +
recent episodes) with a Subscribe button.

## UI search seam

UI declares one more protocol; App implements it over `PodcastSearchService` +
`FeedFetcher`/`FeedParser`.

```swift
// UI module
public protocol PodcastSearchProviding: Sendable {
    /// Concurrent dual-index search, already merged + deduped + badge-tagged.
    func search(term: String) async throws -> [PodcastSearchResult]
    /// Channel metadata + a preview of recent episodes for the detail view,
    /// built by fetching + parsing the live feed (and enriching from the index).
    func detail(feedURL: URL, hint: PodcastSearchResult?) async throws -> PodcastDetail
}

public struct PodcastDetail: Sendable, Hashable {
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: URL?
    public var link: URL?
    public var categories: [String]
    public var sources: Set<PodcastSearchSource>
    public var episodePreview: [PodcastDetailEpisode]   // newest first, capped (e.g. 25)
    public var alreadySubscribed: Bool
}

public struct PodcastDetailEpisode: Sendable, Hashable, Identifiable {
    public var id: String { guid }
    public var guid: String
    public var title: String
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var descriptionHTML: String?
}
```

`PodcastSearchResult` / `PodcastSearchSource` come from the `Podcasts` module; to
avoid a `Podcasts` import in UI, **re-declare lightweight mirrors in UI** (a
`UIPodcastSearchResult` value type) OR move those two value types into a tiny
shared spot UI can already see. Recommended: keep the canonical types in
`Podcasts`, and have the App-layer seam map them into UI-owned mirror structs
(`UIPodcastSearchResult`, with `sources: Set<PodcastSearchSource>` where
`PodcastSearchSource` is re-declared in UI as a plain enum). This keeps the no-
import rule intact. Pick one and be consistent; the rest of this file says
"`PodcastSearchResult`" to mean whichever UI-visible type you land on.

App side:

```swift
struct AppPodcastSearch: PodcastSearchProviding {
    let search: PodcastSearchService
    let fetcher: FeedFetcher
    let parser: FeedParser
    let podcastRepo: PodcastRepository      // to compute alreadySubscribed
    // search(term:) -> map service results to UI mirrors
    // detail(feedURL:hint:) -> service.detail(...) for channel enrich
    //   + fetcher.fetch + parser.parse for the live episode preview
    //   + podcastRepo.fetchByFeedURL(...) != nil for alreadySubscribed
}
```

## Search behaviour (in `PodcastsViewModel`)

Extend `PodcastsViewModel` (phase 21-7) with search state:

```swift
@Published public private(set) var searchResults: [PodcastSearchResult] = []
@Published public private(set) var searchState: PodcastSearchState = .idle    // idle|searching|empty|results|error
@Published public private(set) var addByURLCandidate: URL?                    // non-nil when addBarText is a feed URL
public func onAddBarTextChanged(_ text: String) async   // debounced search driver
public func openDetail(_ result: PodcastSearchResult) async
public func openDetailForURL(_ url: URL) async
```

- **Debounce** ~300 ms; cancel the in-flight search `Task` when the text changes
  (the service honours cancellation). Empty/whitespace -> `.idle`, clear results.
- **Add-by-URL**: if `addBarText` parses as an http(s) URL, set
  `addByURLCandidate`; the results UI shows an "Add this feed" row at the top that
  calls `openDetailForURL`. (Still run a normal search too, in case the URL is
  also a searchable term; harmless.)
- On `search` throwing `.searchUnavailable("all", …)` -> `.error` with a retry;
  on partial availability the service already returns what it has (no error).

## Results presentation

Attach to the Add bar (phase 21-7) as an overlay/popover list that appears while
`searchState != .idle`. Each row:

- Leading: `AsyncImage`/`Artwork`-style thumbnail from `artworkURL` (remote;
  these are not-yet-subscribed shows so there is no local `artwork_path`; a small
  remote image loader with a placeholder is fine. Reuse the app's remote-image
  approach if one exists, else a simple `AsyncImage` with a gradient placeholder).
- Title (feed content) + author (feed content), two lines.
- Trailing: a **source badge** (see below).
- Tap -> `openDetail(result)`.

States: `.searching` shows a slim progress indicator; `.empty` shows "No podcasts
found for «term»"; `.error` shows a retry affordance. All chrome localized.

### Source badge

A small, quiet indicator of provenance, with a tooltip naming the source(s):

- Both sources: show two tiny glyphs (or a combined "PI + Apple" pill).
- Podcast Index only: the Podcast Index mark.
- iTunes only: an Apple mark (`Image(systemName: "applelogo")` is available and
  reads as Apple; tint it secondary).
- For Podcast Index, bundle a small monochrome mark as an asset in the UI module
  (`Resources/`), or use a neutral SF Symbol (`dot.radiowaves.left.and.right`) if
  bundling their logo raises trademark concerns; a tooltip "From Podcast Index"
  carries the meaning regardless.
- The badge has an `accessibilityLabel` spelling out the source(s) ("Found on
  Podcast Index and Apple Podcasts").

Keep it small and secondary; the brief says "a small icon", not a banner.

## Detail view

`PodcastDetailView` presented as a sheet (or pushed destination) when
`openDetail` resolves. Layout:

- Header: large artwork, title, author, category chips, a source badge.
- A Subscribe / Subscribed button:
  - Not subscribed: **Subscribe** -> `actions.subscribe(feedURL:)`; on success
    show a toast and either dismiss to the grid (now showing the new show) or flip
    the button to **Subscribed** / **Go to Show**.
  - Already subscribed (`detail.alreadySubscribed`): show **Subscribed** + a "Go
    to Show" that navigates to `.podcastShow(id)`.
- Description (feed content; render as sanitized rich text, see phase 21-9's HTML
  note - reuse the same sanitizer).
- "Recent Episodes": a compact list of `episodePreview` (title, date, duration).
  Read-only preview; full playback happens after subscribing (the episode list in
  21-9). Optionally allow "Play latest" which subscribes-then-plays, but MVP can
  keep it subscribe-first.
- A **Back** / close affordance (sheet dismiss or `NavigationStack` back).

`detail(feedURL:hint:)` may be slow (it fetches + parses the live feed); show a
loading state in the detail view while it resolves, and handle fetch/parse
failure with a clear message + retry (a dead or moved feed is common).

## Context7 lookups

- None required; SwiftUI over existing patterns. If using `AsyncImage` for remote
  thumbnails, confirm its caching behaviour is acceptable or reuse the app's
  loader.

## Test plan

- **PodcastsViewModel search** (stub `PodcastSearchProviding`): typing drives a
  debounced search; results populate; a URL in the field sets
  `addByURLCandidate`; an all-sources failure sets `.error`; clearing returns to
  `.idle`; changing the term cancels the prior search (assert the stub saw the
  cancellation or only the latest term's result is kept).
- **Source badge** source-convention/snapshot: a both-sources result renders both
  marks; single-source renders one; the accessibility label names the source(s).
- **Detail**: `alreadySubscribed` shows the Subscribed/Go-to-Show state; Subscribe
  calls the action; a failed `detail` resolve shows the error+retry.
- **Snapshots** (`make test-ui`) for the results list (searching/empty/results)
  and the detail view, light + dark.
- **L10n**: all new chrome keys present with `en-XA`; `make pseudolocale` run.

## Acceptance criteria

- [ ] Typing in the Add bar shows merged Podcast Index + iTunes results,
      debounced, cancel-on-change.
- [ ] Each result shows a small source badge with a tooltip + accessibility label
      naming the source(s); both-source hits indicate both.
- [ ] Pasting a feed URL offers "Add this feed" and opens its detail.
- [ ] The detail view shows channel metadata + a recent-episode preview, sourced
      from the live feed, with Subscribe / Subscribed / Back.
- [ ] Subscribe persists the show (via `PodcastActions.subscribe`) and it appears
      in the grid; already-subscribed feeds show the subscribed state.
- [ ] UI imports neither `Podcasts` nor its search clients; the seam is
      `PodcastSearchProviding`, implemented in App.
- [ ] All chrome localized; `make pseudolocale` run; `L10nTests` green.
- [ ] `make test-ui` green; no lint/format warnings.

## Gotchas

- **Debounce + cancel are load-bearing.** Without them, every keystroke fans out
  two network calls and the indexes will rate-limit. 300 ms debounce, cancel the
  prior `Task`.
- **Detail is the live feed, not the index.** Index metadata can be stale; the
  detail view (and subscribe) parse the actual feed so the user sees real, current
  episodes. Show a loading state because this is a network + parse round-trip.
- **Remote thumbnails for not-yet-subscribed shows** have no local
  `artwork_path`; load from `artworkURL`. Only after subscribe does
  `PodcastArtworkCache` produce a local path. Do not block the results list on
  image loads.
- **Badge restraint + trademark.** Keep it a small icon with a tooltip. If
  bundling the Podcast Index logo is a concern, a neutral glyph + tooltip conveys
  the same thing; never imply Apple endorsement.
- **Feed content stays verbatim.** Titles, authors, descriptions, episode titles
  are not localized.
- **Already-subscribed detection** uses `podcastRepo.fetchByFeedURL` on the
  canonical URL; compute it in the App seam so UI does not need the repo.

## Handoff

Phase 21-9 builds the episode list the user reaches after Subscribe (or via the
grid). Phase 21-10 may add "Play latest" / subscribe-and-play niceties and the
settings that govern search (storefront country, Podcast Index key status).
