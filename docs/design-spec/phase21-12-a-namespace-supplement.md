# Phase 21-12-a: Supplementary podcast: namespace parser (funding + chapters)

> Depends on: `phase21-11-feedkit-upgrade.md` (FeedKit on 10.4.0; `FeedParser`
> already rewritten to the 10.x API, `podcastGUID` field and column landed) and
> `phase21-12-podcast-features.md` (the contract for the 21-12 slices). Read
> `_standards.md` and `phase21-0-overview.md` first, then those two, then this.
>
> This is sub-phase a, the Enabler. It is a hard prerequisite for sub-phase c
> (funding affordance) and sub-phase d (chapters list). Build it first.

## Goal

Fill the two Podcasting 2.0 tags FeedKit 10.4.0 does not model, so the columns
that have been written `nil` since the upgrade carry real data:

1. Channel-level `podcast:funding` -> `ParsedFeed.fundingURL` (a URL) plus a new
   `ParsedFeed.fundingText` (the human display label between the element tags).
2. Per-item `podcast:chapters` -> `ParsedEpisode.chaptersURL` (a URL), keyed by
   item `guid` (with enclosure-URL fallback, matching the rest of the module).

Do this with a small, self-contained supplementary parser that reads the SAME
`Data` `FeedFetcher` already returned, runs after FeedKit, and merges by `guid`.
It must be non-fatal and must never touch the FeedKit code path.

## Non-goals

- `podcast:person`, `podcast:soundbite`, `podcast:value`, `podcast:location`, and
  every other Podcasting 2.0 tag (deferred research, per the 21-12 overview).
- Any UI. Surfacing funding is sub-phase c; rendering chapters is sub-phase d.
  This slice only populates the parsed types and the one new column.
- Fetching the chapters JSON document. `chapters_url` is a URL only here; the
  on-demand fetch and parse of the chapters file is sub-phase d.
- Touching the Atom path. `podcast:funding` / `podcast:chapters` are RSS-channel
  and RSS-item tags in real feeds; the supplement targets RSS only, and Atom
  feeds simply yield no extras (same as today).

## Outcome shape (file tree)

```
Modules/Podcasts/Sources/Podcasts/
  Parsing/
    PodcastNamespaceSupplement.swift     (new: the XMLParser-backed supplement)
  FeedParser.swift                       (edit: run supplement after FeedKit, merge by guid)
  Models/
    ParsedFeed.swift                     (edit: add fundingText field + init arg)

Modules/Podcasts/Tests/PodcastsTests/
  PodcastNamespaceSupplementTests.swift  (new)
  FeedParserTests.swift                  (edit: assert funding + chapters populate)
  Fixtures/
    rss-podcast-namespace.xml            (new: funding url+label, two items with chapters)
    rss-namespace-garbage.xml            (new: malformed podcast: payload, must not throw)

Modules/Persistence/Sources/Persistence/
  Records/Podcast.swift                  (edit: add fundingText column mapping)
  Migrations/
    M025_PodcastFundingText.swift        (new)
    Migrator.swift                       (edit: register M025)

Modules/Persistence/Tests/PersistenceTests/
  MigrationTests.swift                   (edit: bump count + schema version to 25)

Modules/Podcasts/Sources/Podcasts/Mapping/ParsedFeed+Records.swift
                                         (edit: pass fundingText to toPodcast)
```

## Data model (the funding_text migration)

`funding_url` and `chapters_url` already exist (added in M023, see
`phase21-0-overview.md`). Only the funding label is new. The next free migration
number is **M025** (M024 is the highest registered; confirm at the top of
`Modules/Persistence/Sources/Persistence/Migrations/Migrator.swift` before
writing). Keep it additive and backfill-free, mirroring `M024_PodcastGUID.swift`:

`Modules/Persistence/Sources/Persistence/Migrations/M025_PodcastFundingText.swift`

```swift
import GRDB

/// Migration 025: adds the `funding_text` column to the `podcasts` table.
///
/// Holds the human label from Podcasting 2.0 `podcast:funding` (the text between
/// the element tags), now that the supplementary parser fills it. See
/// `docs/design-spec/phase21-12-a-namespace-supplement.md`.
///
/// Nullable so existing rows stay valid; populated on the next feed refresh.
enum M025PodcastFundingText {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("025_podcast_funding_text") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "funding_text", .text)
            }
        }
    }
}
```

Register it in `Migrator.make()` directly after `M024PodcastGUID.register(in:&dm)`.

Add to the `Podcast` record (`Records/Podcast.swift`): a
`public var fundingText: String?` property (place it next to `fundingURL`), an
init arg with a `nil` default, the assignment in `init`, and the coding key
`case fundingText = "funding_text"`. Include `funding_text` in the
`PodcastRepository` upsert column list alongside `funding_url` (content fields are
refreshed on every upsert, so a feed that grows a funding label later picks it up).

`ParsedFeed.toPodcast(...)` in `Mapping/ParsedFeed+Records.swift` passes
`fundingText: self.fundingText` (verbatim, never localized; it is feed content).
`chaptersURL` already flows through `ParsedEpisode.toEpisode(...)` into the
existing `chapters_url` column, so no mapping change is needed for chapters.

## Implementation (the supplement + merge)

### `ParsedFeed.fundingText` (additive field)

Add to `Models/ParsedFeed.swift`, next to `fundingURL`:

```swift
/// Podcasting 2.0 `podcast:funding` display label (the element text). Feed
/// content, rendered verbatim, never localized. Nil unless the tag is present.
public var fundingText: String?
```

Add a matching `fundingText: String? = nil` argument to `init` (keep it adjacent
to `fundingURL` so existing callers using positional or trailing args stay
readable) and the `self.fundingText = fundingText` assignment. `ParsedEpisode`
needs no change: `chaptersURL` already exists.

### `PodcastNamespaceSupplement` (new type)

`Modules/Podcasts/Sources/Podcasts/Parsing/PodcastNamespaceSupplement.swift`. A
`Sendable` value type, internal (not `public`) so it stays easy to delete if
FeedKit later models the `podcast:` namespace. It parses the same bytes with
`Foundation.XMLParser` (an `XMLParserDelegate` driver) and extracts ONLY the two
tags, ignoring everything else. Output is a small struct keyed for merge:

```swift
struct PodcastNamespaceSupplement: Sendable {
    struct Result: Sendable {
        var fundingURL: URL?
        var fundingText: String?               // verbatim element text label
        var chaptersByGUID: [String: URL]      // item guid -> podcast:chapters url
    }

    private let log = AppLogger.make(.podcasts)

    /// Best-effort extraction of podcast:funding (channel) and podcast:chapters
    /// (per item). Never throws: any failure logs at debug and returns an empty
    /// Result so the main parse is unaffected.
    func extract(from data: Data) -> Result { ... }
}
```

Delegate notes (verify exact tag shapes via Context7 at implementation, below):

- Match on the local name `funding` / `chapters` within the Podcasting 2.0
  namespace URI `https://podcastindex.org/namespace/1.0`. Use the
  namespace-aware `XMLParser` callbacks (`didStartElement namespaceURI:`) and set
  `parser.shouldProcessNamespaces = true`; do not match on the raw `podcast:`
  prefix, since a feed may bind the namespace to a different prefix.
- `podcast:funding`: read the `url` attribute for `fundingURL`; accumulate the
  characters between start and end into `fundingText` (trim surrounding
  whitespace; nil if empty). It is a channel child, so only capture it while
  inside `<channel>` and NOT inside an `<item>` (track depth with simple
  in-channel / in-item flags). If a feed repeats it, keep the first.
- `podcast:chapters`: read the `url` attribute. It is an item child; capture the
  enclosing item's identity. Track the current item's `guid` (from the item's
  `<guid>` text) and its enclosure `url` (from `<enclosure url=...>`); the merge
  key is `guid` when present, else the enclosure URL, matching
  `FeedParser.parseRSSItem`'s `item.guid?.text ?? urlString` fallback exactly.
  Because `<guid>` and `<enclosure>` can appear in any order relative to
  `<podcast:chapters>` within an item, buffer the chapters URL per-item and
  commit it to `chaptersByGUID` on the item's end element, once the key is known.
- Only keep `http` / `https` URLs (treat feed URLs as untrusted, per the 21-12
  cross-cutting rule); drop anything else. `URL(string:)` failures are skipped.
- Wrap the whole parse so it cannot throw out: on `parser.parse()` returning
  `false` or any internal issue, `log.debug("feed.supplement.failed", [...])` and
  return whatever partial `Result` was accumulated (empty is fine). Honour
  cancellation if the driver loops.

### Wiring into `FeedParser.parse` (the merge)

`FeedParser.parse(_:sourceURL:)` keeps its signature and its FeedKit-first flow
unchanged. After FeedKit produces the `ParsedFeed`, run the supplement over the
same `data` and merge. The merge lives at the end of `parse`, NOT inside
`parseRSS` / `parseAtom`, so the FeedKit mapping helpers stay untouched and the
supplement is one clearly-removable block:

```swift
public func parse(_ data: Data, sourceURL: URL) throws -> ParsedFeed {
    // ... existing FeedKit decode + switch, unchanged ...
    var parsed = try Self.parseRSS(...)   // or parseAtom(...)

    // --- podcast: namespace supplement (remove this block if FeedKit gains
    //     official podcast:funding / podcast:chapters support). Non-fatal. ---
    let extra = PodcastNamespaceSupplement().extract(from: data)
    if parsed.fundingURL == nil { parsed.fundingURL = extra.fundingURL }
    if parsed.fundingText == nil { parsed.fundingText = extra.fundingText }
    if !extra.chaptersByGUID.isEmpty {
        parsed.episodes = parsed.episodes.map { ep in
            guard ep.chaptersURL == nil, let url = extra.chaptersByGUID[ep.guid] else { return ep }
            var e = ep
            e.chaptersURL = url
            return e
        }
    }
    return parsed
}
```

Merge rules: the supplement only fills a field FeedKit left `nil` (FeedKit wins if
it ever starts parsing these). `parseRSS` currently hardcodes `fundingURL: nil`
and `parseRSSItem` hardcodes `chaptersURL: nil`; leave those as the FeedKit-path
defaults so the merge is the single source of these values. The supplement runs
for Atom too but yields nothing, which is correct.

### FeedKit-watch note

Keep the supplement isolated: one new file, an internal type, and a single
clearly-commented merge block in `parse`. If a future FeedKit release models
`podcast:funding` / `podcast:chapters`, delete the file, delete the merge block,
and read the fields directly in `parseRSS` / `parseRSSItem`. The
`ParsedFeed.fundingText` field and the `funding_text` column stay regardless.

## Context7 lookups

At implementation time (not before), verify against current sources:

- `nmdias/FeedKit` (10.4.0): re-confirm that the `podcast:` namespace models still
  cover only `guid` and `transcript`, so the supplement is still needed and is not
  shadowing a now-parsed field. If FeedKit added `funding` / `chapters`, prefer it
  and reduce this slice to the field/column plumbing.
- The Podcasting 2.0 namespace spec (podcastindex-org `podcast-namespace`):
  confirm the canonical namespace URI, that `podcast:funding` carries a `url`
  attribute with the label as element text, and that `podcast:chapters` carries a
  `url` attribute (and a `type`, which we ignore). Confirm `funding` is
  channel-scoped and `chapters` is item-scoped.
- Apple `XMLParser`: confirm the namespace-aware delegate callbacks
  (`shouldProcessNamespaces`, `didStartElement namespaceURI:qualifiedName:`) and
  the `parse()` Bool return / `parserDidEndDocument` semantics.

## Test plan

Swift Testing, no network, fixtures checked in under
`Modules/Podcasts/Tests/PodcastsTests/Fixtures/`, 80% module coverage. Use the
existing `fixture(named:)` helper pattern (`Bundle.module.url(forResource:
withExtension: nil, subdirectory: "Fixtures")`).

- **New fixture `rss-podcast-namespace.xml`:** declares the `podcast:` namespace,
  has a channel `<podcast:funding url="https://example.com/support">Support the
  show</podcast:funding>`, and two `<item>`s each with a `<guid>`, an
  `<enclosure>`, and a `<podcast:chapters url="https://example.com/epN-chapters.json"
  type="application/json+chapters"/>`. Give one item the chapters tag BEFORE its
  `<guid>` and the other AFTER, to exercise order-independence.
- **`FeedParserTests` (end-to-end through `parse`):** assert
  `feed.fundingURL == URL(string: "https://example.com/support")`,
  `feed.fundingText == "Support the show"`, and each
  `episode.chaptersURL` matches the right item by `guid`. Add a parallel case
  using a feed whose item omits `<guid>` so the enclosure-URL fallback key is
  exercised.
- **`PodcastNamespaceSupplementTests` (the type in isolation):** feed it the same
  fixture data and assert the `Result` fields and `chaptersByGUID` keys directly;
  assert merge-by-guid maps each chapters URL to the correct guid.
- **Malformed payload `rss-namespace-garbage.xml`:** truncated / mismatched
  `podcast:` tags and junk attributes. Assert `extract(from:)` returns an empty
  or partial `Result` and does NOT throw, and that `parse` on the same bytes still
  succeeds with `fundingURL`/`fundingText` nil and `chaptersURL` nil (no extras,
  no failure). Also assert the existing regression fixtures (`rss-full.xml`,
  `rss-minimal.xml`, `atom-full.xml`, `not-a-feed.xml`, garbage bytes) still pass
  unchanged: `not-a-feed` and garbage bytes still throw `PodcastsError`.
- **Persistence:** in `MigrationTests.swift`, bump the schema-version assertion
  (`#expect(version == 24)` -> `25`) and the count assertion
  (`#expect(migrator.migrations.count == 24)` -> `25`); update the two test
  display names that say "twenty-four". Add a column check that `podcasts` has
  `funding_text` after migration, and a `toPodcast` -> upsert -> fetch round-trip
  that preserves `fundingText`.

## Acceptance criteria

- [ ] `PodcastNamespaceSupplement` exists as an internal `Sendable` type using
      `XMLParser`, extracting only `podcast:funding` (channel) and
      `podcast:chapters` (per item), keyed by guid with enclosure-URL fallback.
- [ ] `extract(from:)` never throws; failures log at `debug` and yield an empty or
      partial `Result`; only `http`/`https` URLs are kept.
- [ ] `FeedParser.parse` runs FeedKit first, then the supplement over the same
      bytes, then merges by guid, filling only fields FeedKit left `nil`. The
      FeedKit code path (`parseRSS` / `parseRSSItem` / `parseAtom`) is untouched
      except for the single post-merge block, which is clearly commented as
      removable.
- [ ] `ParsedFeed.fundingText` added (additive); `ParsedFeed.fundingURL` and
      `ParsedEpisode.chaptersURL` now populate from real feeds.
- [ ] M025 adds `podcasts.funding_text` (nullable, backfill-free), registered in
      `Migrator.make()`; `Podcast` record maps it; `toPodcast` passes it through;
      the upsert column list includes it.
- [ ] `MigrationTests` count and schema-version assertions are 25; a column check
      and a `fundingText` round-trip pass.
- [ ] New fixtures cover funding (url+label), per-item chapters (both tag orders),
      guid fallback, and a malformed payload that yields nil extras without
      throwing. Existing `FeedParserTests` pass unchanged in intent.
- [ ] `make format && make lint && make build && make test-podcasts &&
      make test-persistence` green; coverage at or above the module floors;
      `make generate` run after any `Package.swift` change (none expected here).

## Gotchas

- **Non-fatal is the whole point.** A throwing supplement that takes down the main
  parse would regress every feed. Catch everything: a `false` from
  `parser.parse()`, a malformed URL, an unexpected nesting. Return partial, log at
  debug, move on. The main parse never depends on the supplement succeeding.
- **Do not touch the FeedKit path.** Keep the merge at the end of `parse`. Do not
  thread the supplement through `parseRSS` / `parseRSSItem`; that entangles the two
  parsers and makes the FeedKit-watch removal a refactor instead of a deletion.
- **Match by namespace URI, not the `podcast:` prefix.** Set
  `shouldProcessNamespaces = true` and key off the namespace URI; a feed can bind
  the namespace to any prefix. Matching the literal `podcast:` string silently
  misses such feeds.
- **`podcast:funding` is channel-scoped; `podcast:chapters` is item-scoped.** Some
  feeds also put a `<funding>` look-alike inside items via other namespaces. Guard
  funding capture to inside `<channel>` and outside `<item>`; guard chapters to
  inside `<item>`. Without the guards you cross-contaminate.
- **Tag order within an item is not guaranteed.** `<podcast:chapters>`, `<guid>`,
  and `<enclosure>` can appear in any order. Buffer the chapters URL per item and
  commit on the item's end element once the merge key (guid, else enclosure URL)
  is resolved, or you will key chapters under an empty string.
- **funding_text is feed content.** Render it verbatim, never through `L10n`. The
  only localized chrome in this whole area (the "Support this show" affordance and
  its confirmation) belongs to sub-phase c, in the UI module.
- **`funding_url` / `chapters_url` already exist (M023).** Do not add columns for
  them. Only `funding_text` is new; M025 is a single `ALTER TABLE ... ADD COLUMN`.
- **No upward imports.** Everything here is `Podcasts` (parser, supplement, mapping)
  and `Persistence` (record, migration). Neither imports UI, Playback, or each
  other beyond the existing `Podcasts -> Persistence` edge.

## Handoff

When this lands: `ParsedFeed.fundingURL`, `ParsedFeed.fundingText`, and
`ParsedEpisode.chaptersURL` carry real values from feeds that publish them, and
the `podcasts.funding_url` / `funding_text` and `podcast_episodes.chapters_url`
columns are populated on subscribe and refresh. Sub-phase c reads
`funding_url` + `funding_text` to render the "Support this show" affordance (with
its confirmation dialog and host display); sub-phase d reads `chapters_url` to
fetch and render the chapter list and to seek through `QueuePlayer`. If FeedKit
later models the `podcast:` namespace, delete `PodcastNamespaceSupplement.swift`
and the one merge block in `FeedParser.parse`, then read the fields directly; the
`fundingText` field and `funding_text` column remain.
