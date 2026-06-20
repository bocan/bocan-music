# Phase 21-12-g: OPML import / export

> Depends on: `phase21-12-podcast-features.md` (the contract for the 21-12
> slices) and the whole Phase 21 feature set (`PodcastService.subscribe`,
> `FeedURL.canonicalKey`, the `PodcastActions` seam, and the `PlaylistIO`
> import/export sheets this slice mirrors). Read `_standards.md` and
> `phase21-0-overview.md` first, then the 21-12 contract, then this. Independent
> of the other 21-12 slices; can land in any order.

## Goal

Move podcast subscriptions in and out as OPML. Two flows:

1. **Import:** read an OPML subscription list, dedupe its feed entries against
   each other and against existing subscriptions via `FeedURL.canonicalKey`, then
   bulk-subscribe through `PodcastService.subscribe(feedURL:)` with progress.
   Unreachable feeds are collected and reported in a summary, never aborting the
   rest, mirroring the `PlaylistIO` import summary/toast pattern.
2. **Export:** serialize the current `subscribedPodcasts()` to an `.opml` file via
   a save panel.

FeedKit does not model OPML, so this is a small dedicated reader (XMLParser) and
writer (string building) in the `Podcasts` module, peers to `FeedParser`.

## Non-goals

- Preserving folder/group hierarchy. OPML allows nested `<outline>` groups;
  import flattens them (descend into nested outlines, collect every feed entry at
  any depth). Export emits a single flat `<body>` list, no grouping.
- Feed fetching beyond what `subscribe` already does. The reader only parses the
  OPML document; it does not validate or fetch the feeds it lists.
- OPML head metadata round-tripping beyond a fixed `<title>` and `dateCreated`.
- A pluggable format abstraction (this is OPML-only, not like `PlaylistFormat`).
- RSS-reader OPML semantics; `type="link"` outlines are simply skipped.

## Outcome shape (file tree)

```
Modules/Podcasts/Sources/Podcasts/
  OPML/
    OPMLReader.swift        (new: XMLParser-backed; outlines -> [OPMLEntry])
    OPMLWriter.swift        (new: OPML 2.0 string builder from subscribed podcasts)
    OPMLModels.swift        (new: OPMLEntry, OPMLImportSummary, OPMLImportItem)
  PodcastService.swift      (edit: add importOPML(data:progress:) and exportOPML())

Modules/Podcasts/Tests/PodcastsTests/
  OPMLReaderTests.swift     (new)
  OPMLWriterTests.swift     (new: round-trip writer -> reader)
  OPMLImportTests.swift     (new: dedupe + partial-failure summary, subscribe stubbed)
  Fixtures/
    opml-flat.opml          (new: flat list of feed outlines)
    opml-nested.opml        (new: grouped/nested outlines)
    opml-missing-xmlurl.opml(new: outlines with no xmlUrl, non-http(s), and a dupe)

Modules/UI/Sources/UI/Browse/Podcasts/
  PodcastSeams.swift           (edit: add OPML methods + mirror summary types)
  PodcastsViewModel.swift      (edit: importOPML / exportOPML driving the seam + toast)
  PodcastOPMLImportSheet.swift (new: file picker, progress, partial-failure summary)
  PodcastsHomeView.swift       (edit: Import/Export menu items + open/save panels)

App/AppPodcastActions.swift    (edit: implement the two new methods over the service)
Modules/UI/Sources/UI/Resources/Localizable.xcstrings (edit: new chrome keys)
```

## Implementation

### Reader (`OPMLReader`)

A `Sendable` enum using `Foundation.XMLParser` with an `XMLParserDelegate`
driver, mirroring `XSPFReader`. OPML 2.0 nests feeds as
`<opml><body><outline ...>`; a feed outline carries `xmlUrl="<feed-url>"` plus
usually `text`/`title`, `htmlUrl`, `type="rss"`. Group outlines have no `xmlUrl`
and contain child `<outline>` elements.

```swift
public enum OPMLReader {
    /// Parses OPML into feed entries. Descends nested outline groups
    /// (flattening) and skips outlines with no usable xmlUrl. Throws
    /// PodcastsError.parseFailed on a malformed XML document.
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> [OPMLEntry]
}
```

Rules: collect one `OPMLEntry` per `<outline>` (any depth) whose `xmlUrl` is a
non-empty `http`/`https` URL; skip group outlines and outlines missing `xmlUrl`
(omit, do not throw). Title precedence is `title` -> `text` -> feed host,
captured verbatim (feed content). Keep `htmlUrl` when present. Treat all
attribute URLs as untrusted: only `http`/`https`, `URL(string:)` failures
skipped. On `parser.parse()` returning `false`, throw
`PodcastsError.parseFailed(url:reason:)` (OPML is the whole input, so a malformed
document is one clear error, unlike the best-effort namespace supplement).

### Writer (`OPMLWriter`)

String building, mirroring `XSPFWriter` (manual XML + the same `escape` helper
for `& < > " '`). Emits OPML 2.0:

```swift
public enum OPMLWriter {
    /// `now` injected for a deterministic dateCreated in tests.
    public static func write(_ podcasts: [Podcast], now: Date = Date()) -> String
}
```

`<?xml ...?>` then `<opml version="2.0">`, a `<head>` with a fixed
`<title>Bocan Podcast Subscriptions</title>` (app-owned metadata, kept English
for round-trip stability, not localized UI chrome) and `<dateCreated>` in RFC 822
(a `DateFormatter` pinned to `en_US_POSIX` + GMT, per the Library convention
against non-Gregorian year drift). Then `<body>` with one self-closing
`<outline type="rss" text="TITLE" title="TITLE" xmlUrl="FEED" htmlUrl="LINK"/>`
per podcast: `text`/`title` from `podcast.title` (verbatim, escaped), `xmlUrl`
from `feedURL`, `htmlUrl` from `podcast.link` only when set.

### Import orchestration (partial-failure summary)

On `PodcastService`, so dedupe and per-feed subscribe stay where both
`FeedURL.canonicalKey` and `subscribe` live:

```swift
public func importOPML(
    data: Data,
    progress: (@Sendable (Int, Int) -> Void)? = nil   // (completed, total)
) async throws -> OPMLImportSummary

public struct OPMLEntry: Sendable, Hashable { var feedURL: URL; var title: String; var htmlURL: URL? }
public struct OPMLImportItem: Sendable, Hashable { var title: String; var feedURL: URL; var reason: String }
public struct OPMLImportSummary: Sendable, Hashable {
    var succeeded: [OPMLImportItem]; var alreadySubscribed: [OPMLImportItem]; var failed: [OPMLImportItem]
    var totalAttempted: Int { succeeded.count + failed.count }
}
```

Algorithm: (1) `OPMLReader.parse` (a malformed document throws here, before any
subscribe); (2) dedupe by `canonicalKey` over parsed entries (drop intra-file
dupes, keep first), then fetch `subscribedPodcasts()`, canonicalize each existing
`feed_url`, and partition into `alreadySubscribed` vs `toSubscribe`; (3)
subscribe `toSubscribe` sequentially, calling `progress(completed, total)` after
each, wrapping every `subscribe` in `do/catch` (success -> `succeeded`, failure
-> `failed` with the `PodcastsError` description, continue), honouring
`Task.checkCancellation()` (a cancelled import returns the summary-so-far, does
not throw); (4) return the summary and log one `info` `podcast.opml.import` with
the three counts. `reason` carries the `PodcastsError` description (already
user-readable via `CustomStringConvertible`).

### Export

```swift
public func exportOPML() async throws -> Data {
    let body = OPMLWriter.write(try await self.subscribedPodcasts(), now: self.now())
    guard let data = body.data(using: .utf8) else { throw PodcastsError.parseFailed(...) }
    return data
}
```

The service returns `Data`; the UI owns the save panel and the atomic
`data.write(to:)`, matching how `PlaylistExportService` serializes while
`PlaylistExportSheet` drives `NSSavePanel`.

### The seam + UI

Extend `PodcastActions` in `PodcastSeams.swift` (UI never imports `Podcasts`; the
App adapter forwards to `PodcastService`):

```swift
func importOPML(data: Data, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> UIOPMLImportSummary
func exportOPML() async throws -> Data
```

Mirror `OPMLImportSummary` / `OPMLImportItem` in UI as `UIOPMLImportSummary` /
`UIOPMLImportItem` (the App adapter maps between them), exactly like
`PodcastSeams.swift` already mirrors `PodcastSearchResult`. `AppPodcastActions`
implements both as thin pass-throughs to the service, mapping the summary type.

UI surfaces:

- **Menu items** in `PodcastsHomeView` (a toolbar `Menu`):
  "Import Subscriptions..." and "Export Subscriptions...", both localized.
- **Import** opens an `NSOpenPanel` (`allowedContentTypes` =
  `UTType(filenameExtension: "opml")` plus `.xml`, single selection) via the
  non-blocking `begin { }` continuation from `PlaylistImportSheet.pickFiles`,
  then presents `PodcastOPMLImportSheet`: it reads the file, calls
  `actions.importOPML(data:progress:)`, shows a determinate
  `ProgressView(value:total:)` driven by the progress callback (hopped to
  MainActor), and on completion shows added / skipped (already subscribed) /
  failed counts plus a scrollable list of failed feeds and reasons, mirroring
  `PlaylistImportSheet`'s matched/missing presentation. A non-empty success also
  fires a `PodcastsViewModel.showToast` ("Imported N subscriptions").
- **Export** calls `actions.exportOPML()`, then an `NSSavePanel`
  (`nameFieldStringValue = "Podcast Subscriptions.opml"`, `allowedContentTypes` =
  opml) via the `begin { }` pattern from `PlaylistExportSheet.runExport`, and
  writes the returned `Data` atomically; errors toast. Skip the panel when there
  are no subscriptions (toast "No subscriptions to export").

All chrome (menu titles, panel prompts, progress label, summary headings, and the
plural-aware counts) routes through `L10n` with keys in `Localizable.xcstrings`;
plural strings use stringsdict variations like the existing `"\(matched) matched"`
keys; run `make pseudolocale` after adding keys. Podcast titles in the summary and
the OPML are feed content, rendered verbatim.

## Context7 lookups

At implementation time (not before), verify against current sources:

- **OPML 2.0 spec** (opml.org): confirm the document shape
  (`<opml version="2.0"><head/><body><outline .../></body></opml>`), that feeds
  use the `xmlUrl` attribute (exact camelCase), that `htmlUrl` / `text` / `title`
  / `type="rss"` are the conventional outline attributes, and that nested
  `<outline>` groups are legal and carry no `xmlUrl`.
- Apple **`XMLParser`**: confirm the `didStartElement attributes:` callback and
  the `parse()` Bool return, matching `XSPFReader`.
- **`UniformTypeIdentifiers`** + `NSOpenPanel`/`NSSavePanel`: confirm
  `UTType(filenameExtension: "opml")` and `allowedContentTypes`, matching the
  `PlaylistIO` sheets.

## Test plan

Swift Testing, no network, fixtures checked in under
`Modules/Podcasts/Tests/PodcastsTests/Fixtures/`, 80% module coverage. Subscribe
is stubbed via the existing `PodcastService` test seams (the `URLProtocol` /
`HTTPClient` mock from `PodcastServiceTests`).

- **Reader / `opml-flat.opml`:** assert the exact feed-URL set and titles
  (`title`/`text` resolution).
- **Reader / `opml-nested.opml`:** assert the reader descends every group and
  returns the full flattened feed list.
- **Reader / `opml-missing-xmlurl.opml`:** outlines with no `xmlUrl`, a
  non-http(s) `xmlUrl`, and an intra-file duplicate; assert invalid entries are
  skipped (no throw) and valid ones returned.
- **Reader / malformed XML:** truncated document throws `PodcastsError.parseFailed`
  (does not silently return `[]`).
- **Writer round-trip:** build `[Podcast]` (with and without `link`), `write`,
  parse the output back, assert feed URLs / titles / htmlUrls survive and that an
  XML-special character in a title is escaped and re-read intact; pin `now`.
- **Import dedupe + partial failure:** drive `importOPML` with one entry already
  subscribed (matched only after `canonicalKey` normalizes an http/https + `www.`
  variant), one that subscribes cleanly, and one whose stubbed fetch fails; assert
  one `alreadySubscribed`, one `succeeded`, one `failed` (with reason),
  `totalAttempted` excludes the skip, no throw, and `progress` called `total`
  times with monotonically increasing `completed`.
- **Cancellation:** cancel mid-import; assert it returns the summary-so-far
  without throwing.

## Acceptance criteria

- [ ] `OPMLReader.parse` extracts feed outlines at any depth (flattening),
      keeps only `http`/`https` `xmlUrl`s, resolves titles (`title` -> `text` ->
      host) verbatim, skips outlines with no usable `xmlUrl`, and throws
      `PodcastsError.parseFailed` on malformed XML.
- [ ] `OPMLWriter.write(_:now:)` emits valid OPML 2.0 (fixed head title + RFC 822
      `dateCreated`, flat `<body>` of `type="rss"` outlines with escaped
      attributes) that round-trips back through the reader.
- [ ] `PodcastService.importOPML` dedupes candidates and existing subscriptions
      via `FeedURL.canonicalKey`, subscribes the rest sequentially with progress,
      collects per-feed failures without aborting, honours cancellation, and
      returns an `OPMLImportSummary` (succeeded / alreadySubscribed / failed).
- [ ] `PodcastService.exportOPML()` returns UTF-8 OPML `Data` for current
      subscriptions.
- [ ] `PodcastActions` gains `importOPML` and `exportOPML`; `AppPodcastActions`
      implements both over `PodcastService` (mapping the summary type); UI mirrors
      the summary/item types and never imports `Podcasts`.
- [ ] UI adds localized Import/Export menu items, an open panel + import sheet with
      determinate progress and a succeeded/skipped/failed summary (failed feeds
      listed with reasons), and a save panel that writes the bytes atomically;
      empty-subscription export and import success both toast.
- [ ] All chrome routes through `L10n` with plural-aware count strings;
      `make pseudolocale` run; OPML and summary podcast titles are verbatim.
- [ ] `make format && make lint && make build && make test-podcasts &&
      make test-ui` green; coverage at or above floors; `make generate` run after
      adding the new UI test/source files so the Xcode bundle globs them.

## Gotchas

- **Malformed OPML throws once, up front.** Unlike the namespace supplement
  (best-effort augmentation), OPML is the entire input: a bad document surfaces one
  clear error before any subscribe, not a silent zero-feed import. The reader
  throws and the orchestration lets it propagate.
- **Dedupe vs already-subscribed are different buckets.** Intra-file duplicates
  collapse silently (keep first); entries matching an existing subscription go to
  `alreadySubscribed` (reported and skipped, not retried). Both comparisons use
  `FeedURL.canonicalKey`, so an http/https or `www.` variant of a subscribed feed
  is correctly recognized as a duplicate.
- **`subscribe` is idempotent, so a missed dupe is harmless** (it upserts), but do
  not lean on that as the dedupe: a feed that 404s would then be reported as a
  failure when it is really a skip. Canonicalize before subscribing.
- **Large lists.** Subscribe sequentially (each is a fetch + DB upsert); do not
  fan out hundreds of concurrent fetches. Report progress so a 200-feed import is
  not a frozen sheet, and keep `Task.checkCancellation()` in the loop. Artwork
  caching is already fire-and-forget inside `subscribe`, so it does not serialize
  the import.
- **Partial-failure reporting is the contract.** One unreachable feed never aborts
  the batch; collect `(title, feedURL, reason)` per failure and show them, mirroring
  `PlaylistIO`'s matched/missing summary so the two import experiences match.
- **No upward imports.** Reader/writer/import live in `Podcasts`; the seam and
  sheets in `UI`; the adapter in `App`. UI mirrors the summary types rather than
  importing `Podcasts`, like the search-result mirror already in `PodcastSeams.swift`.
- **Feed content is verbatim.** OPML outline titles and the titles in the summary
  are show content, never localized; only surrounding chrome is. The writer's head
  `<title>` is a fixed app-owned metadata string.

## Handoff

When this lands: a user can import an OPML subscription list from another podcast
app and have every reachable feed subscribed in one pass, with duplicates and
already-subscribed feeds skipped and unreachable feeds reported in a summary, and
can export current subscriptions back to an `.opml` file. The reader, writer, and
import orchestration live in `Podcasts` (`OPML/`), the `PodcastActions` seam
carries `importOPML` / `exportOPML`, and the UI reuses the `PlaylistIO`
file-picker + partial-failure summary idiom. If a later phase adds folder/group
support, the reader already descends nested outlines (it just flattens today) and
the writer's flat `<body>` is the natural place to introduce grouping.
