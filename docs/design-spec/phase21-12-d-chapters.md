# Phase 21-12-d: Chapters in Now Playing

> Depends on: `phase21-12-a-namespace-supplement.md` (the supplementary `podcast:`
> parser fills `podcast_episodes.chapters_url`; without it almost no episode has a
> chapters URL to fetch). Read `_standards.md`, `phase21-0-overview.md`, and the
> contract `phase21-12-podcast-features.md` first. Builds on phase 21-5 playback
> (`PlayableSource.podcast`, `QueuePlayer`) and phase 21-10 Now Playing podcast mode.

## Goal

When a podcast episode that ships chapters (a populated `chapters_url`) is playing,
Now Playing shows a chapter list. Tapping a chapter seeks to its start time. A live
"current chapter" label sits under the episode title, derived from the playback
position. Chapters are fetched on demand from the URL; there is no database table.

## Non-goals

- No chapter editing, authoring, or persisting chapter data in the DB.
- No embedded ID3 / MP4 chapter reading (a documented stretch: those come from the
  audio file via the `Metadata` module, not over HTTP here, and need a separate path).
- No chapter-image slideshow (parse `img` onto the value type, but rendering it is out).
- No `podcast:soundbite`, no chapter-level sharing.

## Outcome shape (file tree)

```
Modules/Podcasts/Sources/Podcasts/Chapters/
  Chapter.swift               # value type + current(at:) helper
  ChaptersFetcher.swift       # fetch chapters_url via HTTPClient, parse JSON
  ChaptersCache.swift         # optional on-disk cache, modeled on PodcastArtworkCache
Modules/Podcasts/Tests/PodcastsTests/ChaptersFetcherTests.swift
Modules/Podcasts/Tests/PodcastsTests/Fixtures/chapters-pc20.json       # hand-authored PC2.0 fixture
Modules/Podcasts/Tests/PodcastsTests/Fixtures/chapters-malformed.json  # degrade-case fixture
Modules/UI/Sources/UI/Browse/Podcasts/PodcastSeams.swift   # + UIChapter, + chapters() seam
Modules/UI/Sources/UI/Transport/ChapterListView.swift      # the chapter list
Modules/UI/Sources/UI/ViewModels/NowPlayingViewModel+Chapters.swift
App/AppPodcastActions.swift # implements chapters(podcastID:guid:) over PodcastService
```

`make generate` after the `Package.swift` change and the new `UI/Tests` file (the
Xcode `BocanTests` bundle globs `ViewModelTests`).

## Implementation

### Fetch and parse (`Podcasts` module)

`Chapter` is the normalized, source-agnostic value type (`Sendable, Hashable, Identifiable`):
`id: Int` (sorted index), `startTime: TimeInterval` (seconds), `title: String`,
`imageURL: URL?` (chapter `img`), `url: URL?` (chapter link).

`ChaptersFetcher` is an `actor` injected with `any HTTPClient` (default
`URLSession.shared`), mirroring `FeedFetcher` / `PodcastArtworkCache`:

```swift
public actor ChaptersFetcher {
    public init(http: any HTTPClient = URLSession.shared, cache: ChaptersCache? = nil)
    public func chapters(for url: URL) async throws -> [Chapter]
}
```

- Set `User-Agent` ("Bocan Podcast-Reader", matching `PodcastArtworkCache`), a 10 s
  timeout, and a 1 MB size cap (chapter JSON is tiny; reject larger as hostile).
  Reject non-2xx with a `PodcastsError` case.
- Decode the Podcasting 2.0 JSON chapters document with `Codable`: a top-level object
  with a `chapters` array, each entry having `startTime` (seconds, required),
  `title`, and optional `img` / `url`. Tolerate missing optional keys and unknown
  extra keys; skip an entry with no `startTime` rather than failing the whole parse.
- Sort ascending by `startTime`, assign `id` = sorted index, return `[Chapter]`.
- Verify exact field names / types at implementation via Context7 (below). Chapter
  `title` is feed content: rendered verbatim, never localized.
- Log via `AppLogger.make(.podcasts)`: `chapters.fetch.start` / `.end` (`count`) /
  `.failed` (`["error": String(reflecting: err)]`). Errors degrade to "no chapters",
  never a blocking alert.

`ChaptersCache` (optional, behind `cache:`) copies the `PodcastArtworkCache` pattern:
an `actor` writing under
`~/Library/Application Support/io.cloudcauldron.bocan/Podcasts/Chapters/`, filename a
truncated SHA-256 of the chapters URL, storing the parsed `[Chapter]` as JSON,
best-effort (failures log and fall through to a live fetch). An in-memory dictionary
keyed by URL inside `ChaptersFetcher` is an acceptable first cut; the on-disk cache is
the documented upgrade sharing the file-layout convention. Either way it is a cache,
never the source of truth.

`PodcastService` gains a facade so the seam has one object to call:

```swift
public func chapters(podcastID: Int64, guid: String) async throws -> [Chapter]
```

It looks up the episode (`EpisodeRepository`), reads `chapters_url`, returns `[]`
when `nil`, else delegates to `ChaptersFetcher`.

### Current-chapter logic (pure, host-less testable)

Lives next to `Chapter` in the `Podcasts` module so it is unit-tested without a view
tree, and is mirrored UI-side on `[UIChapter]`:

```swift
extension Array where Element == Chapter {
    func current(at position: TimeInterval) -> Chapter? { last { $0.startTime <= position } }
}
```

Boundary behaviour pinned by tests: before the first `startTime` returns `nil` (label
hidden); strictly between two starts returns the earlier; at or after the last returns
the last; empty list returns `nil`.

### Seek wiring (transport only)

`NowPlayingViewModel.scrub(to:)` already calls `engine.seek(to:)` on the injected
`any Transport` (the `QueuePlayer`); `QueuePlayer.seek(to:)` is the single seek entry
point. The chapter list calls `await vm.scrub(to: chapter.startTime)`. No new transport
seam is added and AudioEngine is never touched from UI: the contract's "add a
seek-to-time seam if one does not exist" clause is satisfied by the existing
`scrub(to:)` -> `Transport.seek` -> `QueuePlayer.seek` chain, so this slice reuses it.
A future podcast-only seek would go on `PodcastActions` and be implemented in `App`
over `QueuePlayer`, never reaching into the engine.

### The seam (UI declares, App implements)

UI never imports `Podcasts`, so `PodcastSeams.swift` gains a mirror type and a method
on the existing `PodcastActions` command seam:

```swift
public struct UIChapter: Sendable, Hashable, Identifiable {
    public var id: Int
    public var startTime: TimeInterval
    public var title: String
    public var imageURL: URL?
    public var url: URL?
}

public protocol PodcastActions: Sendable {
    // ... existing members ...
    /// Returns [] when the episode has no chapters URL or the fetch fails.
    func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter]
}
```

`App/AppPodcastActions.swift` implements it over `PodcastService`, mapping
`[Chapter]` -> `[UIChapter]` (same hand-mapping as `UIPodcastSearchResult`). The UI passes
`vm.podcastID` + `vm.podcastGUID`, both already on `NowPlayingViewModel`. The App
already holds `PodcastService`, so `chapters_url` reachable through `podcastID` +
`guid` is its lookup.

### UI (Now Playing podcast mode)

- Put the additions in a `NowPlayingViewModel+Chapters.swift` extension (the VM is at
  the SwiftLint 500-line `file_length` limit). Add `private(set) var chapters:
  [UIChapter] = []`, a derived `var currentChapter: UIChapter? {
  self.chapters.current(at: self.position) }`, and `func loadChapters() async` calling
  the injected `PodcastActions.chapters(...)`. Call `loadChapters()` from
  `applyPodcastItem(...)` and clear `chapters` in `clearNowPlayingDisplay()` / when
  switching to a non-podcast item. The existing 0.5 s position poll already drives
  `position`, so `currentChapter` updates live with no extra timer.
- `ChapterListView` renders when `!vm.chapters.isEmpty`: each row shows the chapter
  `title` (verbatim) and start time via `Duration.formatted`, highlights the row equal
  to `vm.currentChapter`, and on tap calls `await vm.scrub(to: row.startTime)`.
  Simplest home: a popover/disclosure button in `PodcastTransportControls`, shown only
  when chapters exist.
- The live current-chapter label is `Text(vm.currentChapter?.title ?? "")` under the
  episode title in the strip's podcast branch, hidden when `currentChapter` is `nil`.

### Localized chrome (UI catalog only)

New `L10n` keys in `Resources/Localizable.xcstrings`: section header ("Chapters"),
empty state ("No chapters"), list-button a11y label ("Show chapters"), and a per-row
a11y format string ("Chapter: %@ at %@" with title + formatted time). Chapter titles
are feed content, never a catalog key. Run `make pseudolocale` after adding keys or the
en-XA coverage test fails. Every row is keyboard- and VoiceOver-reachable per
`_standards.md`.

## Context7 lookups

- **Podcasting 2.0 chapters JSON schema**: confirm the top-level shape
  (`{ "version": ..., "chapters": [...] }`), field names (`startTime`, `title`, `img`,
  `url`, plus `endTime`, `toc`), and units (seconds, floating point) before finalizing
  the `Codable` types; treat optional fields as optional.
- **Foundation `Duration.formatted` / `Date.FormatStyle`**: confirm the current API for
  rendering a `TimeInterval` as `H:MM:SS` for the row time and a11y string.
- Use the latest stable docs for any dependency; avoid deprecated APIs.

## Test plan

All in `Modules/Podcasts/Tests/PodcastsTests/`, Swift Testing, no network (the existing
`MockHTTPClient` / `HTTPClient` stub used by `FeedFetcherTests`):

- **Parse correctness** against `chapters-pc20.json`: count, ascending sort, `startTime`
  / `title` parsed, optional `img` / `url` populated when present and `nil` when absent.
- **Graceful degradation** against `chapters-malformed.json`: an entry missing
  `startTime` is skipped, garbage extra keys ignored, an empty `chapters` array yields
  `[]`; a non-2xx response and an oversized body each throw the expected `PodcastsError`
  (caller maps to `[]`).
- **Current-chapter computation** (`[Chapter].current(at:)`), table-driven via
  `arguments:`: before first -> `nil`; on a boundary -> that chapter; strictly between
  -> the earlier; after last -> the last; empty -> `nil`.
- **Cache** (if built): a second `chapters(for:)` for the same URL does not hit the HTTP
  mock again (assert call count); a corrupt cache file falls through to a live fetch.
- **UI**: a source-convention test that `ChapterListView` calls `scrub(to:)` (seek via
  the VM, not the engine) and that header / empty-state copy routes through `L10n`.

Fixtures are checked in, never generated at test time. Run `make test-podcasts` and
`make test-ui` before committing.

## Acceptance criteria

- [ ] `Chapter` and `ChaptersFetcher` exist in `Podcasts`; fetch uses the `HTTPClient`
      seam with `User-Agent`, timeout, and a size cap.
- [ ] Podcasting 2.0 JSON chapters parse into a sorted `[Chapter]`; malformed entries
      are skipped, not fatal.
- [ ] `[Chapter].current(at:)` is correct for before-first, between, on-boundary,
      after-last, and empty (tests pin all five).
- [ ] `PodcastActions` gains `chapters(podcastID:guid:) -> [UIChapter]`, declared in
      `PodcastSeams.swift`, implemented in `App`; UI does not import `Podcasts`.
- [ ] Now Playing podcast mode shows a chapter list and a live current-chapter label
      when chapters exist; both hidden when none.
- [ ] Tapping a chapter seeks via `NowPlayingViewModel.scrub(to:)`; AudioEngine is never
      called directly from UI.
- [ ] All chrome localized via `L10n`; chapter titles verbatim; `make pseudolocale` run
      and en-XA coverage passes.
- [ ] No network in tests; hand-authored fixtures checked in under `PodcastsTests/Fixtures/`.
- [ ] `make format && make lint && make build && make test-podcasts && make test-ui`
      green; `make generate` run after the new files.

## Gotchas

- **Seek via `QueuePlayer` only.** Reuse `scrub(to:)`; never call `AudioEngine` from UI.
  The transport gate exists for a reason; bypassing `QueuePlayer.seek` strands the
  buffer pump.
- **Mapping is "last start <= position", not nearest.** A position before the first
  `startTime` has no current chapter (label hidden), which is correct. Recompute from the
  live `position`; do not cache a stale index across a seek.
- **Fetch failures degrade gracefully.** Network error, non-2xx, oversized body, or
  unparseable JSON all collapse to "no chapters" (empty list, hidden), a debug/warning
  log, and no blocking UI. A show without `chapters_url` simply has no affordance.
- **`chapters_url` comes from sub-phase a.** Before the supplement runs the column is
  `nil` for almost every episode, so the feature looks inert; that is expected and is why
  this slice depends on `a`.
- **Embedded ID3/MP4 chapters are a different path (stretch).** They live in the audio
  file and would be read through `Metadata` (TagLib), then surfaced through the same
  `[UIChapter]` UI; do not bolt that onto `ChaptersFetcher`.
- **`NowPlayingViewModel` is at the file-length limit.** Add chapters state in the
  `+Chapters.swift` extension, not inline.
- **Do not localize chapter titles.** Only the surrounding chrome is localized.

## Handoff

After this slice: episodes with a `chapters_url` show a tappable chapter list and a live
current-chapter label in Now Playing, seeking through the existing transport path.
`Chapter` / `ChaptersFetcher` (and the optional `ChaptersCache`) are the home for future
chapter work; embedded ID3/MP4 chapters can later feed the same `[UIChapter]` UI through
a `Metadata`-backed reader without changing the seam. No DB migration was added; if a
future phase wants offline chapters, the on-disk `ChaptersCache` is the place, or a table
can be added then.
