# Phase 21-3: Podcasts - Dual-index search (Podcast Index + iTunes), dedupe/merge

> Depends on: `phase21-0-overview.md`, `phase21-2-feeds.md` (the `Podcasts`
> module, `PodcastsError`, `HTTPClient`, `FeedURL` already exist). Same module,
> separate slice.
>
> Provides: `PodcastIndexClient`, `ITunesSearchClient`, `PodcastSearchService`
> (the concurrent fan-out + merge), and the `PodcastSearchResult` /
> `PodcastSearchSource` types from the overview.

## Goal

Search Podcast Index and the Apple iTunes search API **at the same time**, merge
and deduplicate the results, prefer the richer Podcast Index fields for display,
and tag each result with which source(s) it came from so the UI can show a badge.
Degrade gracefully: if one source is unavailable (no key, network, rate limit),
return the other's results rather than failing.

This slice is the network + algorithm layer. The UI that renders results and the
detail/subscribe flow are phases 21-8 / 21-4.

## Non-goals

- No UI. The result list, badges, and detail view are phase 21-8.
- No subscription writes. Subscribe is phase 21-4.
- Episode-level search inside the index APIs is out of scope; search is
  show-level discovery. (We fetch episodes by parsing the feed in 21-4/21-8.)

## Outcome shape

```
Modules/Podcasts/Sources/Podcasts/
├── Search/
│   ├── PodcastSearchService.swift       # actor: fan-out + merge + dedupe
│   ├── PodcastIndexClient.swift         # authed JSON client
│   ├── ITunesSearchClient.swift         # keyless JSON client
│   ├── PodcastIndexAuth.swift           # X-Auth-* header signer (SHA1)
│   └── Models/
│       ├── PodcastSearchResult.swift    # (from overview)
│       ├── PodcastSearchSource.swift    # (from overview)
│       └── PodcastIndexCredentials.swift
└── Tests/PodcastsTests/
    ├── PodcastSearchServiceTests.swift
    ├── PodcastIndexClientTests.swift
    ├── ITunesSearchClientTests.swift
    └── Fixtures/
        ├── podcastindex-search.json
        ├── itunes-search.json
        └── podcastindex-byfeedurl.json
```

## API credentials

Podcast Index requires an API key + secret; iTunes is keyless. Follow the
existing secret-injection pattern (AcoustID / Last.fm keys come from
`Secrets.xcconfig` to Info.plist build constants, read at runtime):

- Add `PODCAST_INDEX_API_KEY` and `PODCAST_INDEX_API_SECRET` to
  `Secrets.xcconfig.template` (empty) and document them in `DEVELOPMENT.md`.
- Surface them into the app's Info.plist (the App layer reads them and constructs
  `PodcastIndexCredentials`, then injects into `PodcastSearchService`). The
  `Podcasts` module itself takes credentials as an init parameter; it never reads
  Info.plist (keeps the module host-agnostic and testable).
- When the key/secret are empty, `PodcastSearchService` runs **iTunes-only** and
  every result is sourced `.itunes`. This must be a clean, expected path, not an
  error, so contributors without a Podcast Index key still get working search.

```swift
public struct PodcastIndexCredentials: Sendable {
    public var apiKey: String
    public var apiSecret: String
    public var isConfigured: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }
    public init(apiKey: String, apiSecret: String)
}
```

## `PodcastIndexAuth`

Podcast Index auth: every request sends three headers. The `Authorization`
header is `SHA1(apiKey + apiSecret + unixSeconds)` as lowercase hex.

```swift
enum PodcastIndexAuth {
    /// Returns the three required headers for a given request time.
    /// X-Auth-Key: <apiKey>
    /// X-Auth-Date: <unixSeconds>
    /// Authorization: <sha1Hex(apiKey + apiSecret + unixSeconds)>
    static func headers(credentials: PodcastIndexCredentials, now: Date) -> [String: String]
}
```

Use `Crypto`/`CryptoKit`'s `Insecure.SHA1` (SHA1 is required by the API; it is a
request signature, not a security primitive). Inject `now` so tests are
deterministic. A `User-Agent` header is also required by Podcast Index; reuse the
one from `FeedFetcher`.

## `PodcastIndexClient`

```swift
public actor PodcastIndexClient {
    public init(credentials: PodcastIndexCredentials,
                http: any HTTPClient = URLSession.shared,
                now: @escaping @Sendable () -> Date = { Date() })

    /// GET https://api.podcastindex.org/api/1.0/search/byterm?q=<term>
    public func search(term: String, max: Int = 40) async throws -> [PodcastSearchResult]

    /// GET .../podcasts/byfeedurl?url=<feed>  - rich detail for the detail view.
    public func podcast(byFeedURL: URL) async throws -> PodcastSearchResult?
}
```

- Base URL `https://api.podcastindex.org/api/1.0`.
- `Accept: application/json`, the three auth headers, `timeoutInterval` 15 s.
- Decode the documented JSON shape into private `Codable` DTOs, then map to
  `PodcastSearchResult` (set `sources = [.podcastIndex]`, fill
  `podcastIndexID`, `feedURL` from the `url` field, `episodeCount`,
  `lastPublishedAt` from `newestItemPubdate`, `categories` from the `categories`
  map values).
- On HTTP 401/403, throw `PodcastsError.searchUnavailable(source:
  "podcastIndex", reason:)` (the service catches it and degrades). On 429,
  same, with a rate-limit reason.
- `try Task.checkCancellation()` before the request.
- Never log the secret or the rendered `Authorization` header (add `apiSecret`
  and `authorization` are already in `Observability.sensitiveKeys`; verify and
  extend if needed).

## `ITunesSearchClient`

```swift
public actor ITunesSearchClient {
    public init(http: any HTTPClient = URLSession.shared)

    /// GET https://itunes.apple.com/search?media=podcast&term=<term>&limit=<n>&country=<cc>
    public func search(term: String, limit: Int = 40, country: String = "US") async throws -> [PodcastSearchResult]

    /// GET https://itunes.apple.com/lookup?id=<collectionId> - detail fallback.
    public func lookup(collectionID: Int) async throws -> PodcastSearchResult?
}
```

- Keyless. `timeoutInterval` 15 s, `Accept: application/json`.
- Map the `results[]` entries: `feedURL` from `feedUrl`, `title` from
  `collectionName`/`trackName`, `author` from `artistName`, `artworkURL` from
  `artworkUrl600` (prefer the largest), `itunesCollectionID` from `collectionId`,
  `categories` from `genres`, `episodeCount` from `trackCount`. Set
  `sources = [.itunes]`. Some iTunes rows lack a `feedUrl` (skip those; they are
  not subscribable).
- `country` defaults to "US" for MVP; a later enhancement can use the user's
  storefront. Make it a parameter so that is a one-line change.

## `PodcastSearchService` (the fan-out + merge)

```swift
public actor PodcastSearchService {
    public init(podcastIndex: PodcastIndexClient?,   // nil when no credentials
                itunes: ITunesSearchClient,
                log: AppLogger = .make(.network))

    /// Run both sources concurrently, merge, dedupe, and return the combined
    /// list ordered by relevance. Never throws when at least one source
    /// succeeds; throws .searchUnavailable only when ALL sources fail.
    public func search(term: String) async throws -> [PodcastSearchResult]

    /// Rich detail for a single feed: prefer Podcast Index, fall back to iTunes,
    /// fall back to a bare result built from the feed URL. Used by the detail view.
    public func detail(for result: PodcastSearchResult) async -> PodcastSearchResult
}
```

### Fan-out

Run both in parallel and tolerate partial failure. Use `async let` (two fixed
sources) or a `TaskGroup`:

```swift
async let pi = self.podcastIndex?.search(term: term)   // returns [] when nil
async let it = self.itunes.search(term: term)
let piResult = await captureResult { try await pi ?? [] }   // -> Result
let itResult = await captureResult { try await it }
// If BOTH are .failure -> throw .searchUnavailable("all", …)
// Otherwise proceed with whatever succeeded; log a warning for the failed one.
```

Apply a per-source soft timeout (e.g. 8 s) so one slow source does not stall the
combined result; a timed-out source is treated as an empty failure and logged.

### Dedupe + merge

1. Bucket every result by `FeedURL.canonicalKey(result.feedURL)` (from 21-2).
2. For each bucket, fold into one `PodcastSearchResult`:
   - `sources` = union of all sources in the bucket.
   - Display fields (`title`, `author`, `artworkURL`, `description`,
     `episodeCount`, `lastPublishedAt`, `categories`): **prefer the Podcast Index
     member**; fall back to the iTunes member's value where the preferred one is
     nil/empty. (Podcast Index data is richer and more current per the brief.)
   - `feedURL`: prefer the `https` variant; otherwise the Podcast Index one.
   - Carry both `podcastIndexID` and `itunesCollectionID` when known.
3. Secondary dedupe for results that have **no** feed URL match but are clearly
   the same show: bucket the remaining singletons by
   `normalized(title) + "\u{1}" + normalized(author)` where `normalized`
   lowercases, trims, and strips punctuation/whitespace runs. Merge collisions
   the same way. (Most shows match on feed URL; this catches the few where one
   index has a slightly different feed URL, e.g. a tracking-prefixed URL.)
4. Order the merged list: results present in **both** sources first (strongest
   signal), then Podcast-Index-only, then iTunes-only; within each group preserve
   the source's original relevance order (Podcast Index order wins when both).
   Keep it simple and deterministic; this is discovery, not precision ranking.

### `detail(for:)`

When the user clicks a result, the detail view wants the richest channel data.
`detail` returns an enriched `PodcastSearchResult`:

- If the result is sourced from Podcast Index (or PI is configured), call
  `podcastIndex.podcast(byFeedURL:)` and merge over the existing result.
- Else if it has an `itunesCollectionID`, call `itunes.lookup(collectionID:)`.
- Else return the result unchanged.

The actual episode list shown in the detail view comes from parsing the feed
(phase 21-8 calls `FeedFetcher` + `FeedParser`), not from the index APIs, so this
method only enriches channel metadata. Never throw from `detail`; return the best
available on failure.

## Context7 lookups

- Podcast Index API docs: the `/search/byterm` and `/podcasts/byfeedurl`
  response JSON shapes, the required auth headers, and the SHA1 signing recipe.
- Apple iTunes Search API: `media=podcast` parameters, the `results[]` fields,
  artwork size variants, and the `lookup` endpoint.
- `apple/swift-crypto` or `CryptoKit`: `Insecure.SHA1` hashing to hex.

## Dependencies

None new beyond CryptoKit (system framework). The `Secrets.xcconfig` keys are
config, not SPM dependencies.

## Test plan

No network. Inject an `HTTPClient` mock that returns fixture bytes keyed by URL,
and inject a fixed `now` for deterministic PI signatures.

- **PodcastIndexClientTests**: signs the three headers correctly for a known
  `(key, secret, now)` (assert the SHA1 hex); decodes
  `podcastindex-search.json` into `PodcastSearchResult`s with
  `sources == [.podcastIndex]`; 401 throws `.searchUnavailable`.
- **ITunesSearchClientTests**: decodes `itunes-search.json`; rows without
  `feedUrl` are dropped; `sources == [.itunes]`; picks the largest artwork.
- **PodcastSearchServiceTests** (the important one):
  - Both sources return the same show (same feed URL up to http/https + `www.` +
    trailing slash): one merged result, `sources == [.podcastIndex, .itunes]`,
    display fields taken from Podcast Index.
  - Podcast-Index-only and iTunes-only shows both appear, tagged with one source.
  - Ordering: both-source results sort ahead of single-source ones.
  - Secondary title+author dedupe merges two results whose feed URLs differ only
    by a tracking prefix but whose title+author match.
  - One source throws: the other's results still return; a warning is logged; no
    throw.
  - Both sources throw: `.searchUnavailable("all", …)` is thrown.
  - No Podcast Index credentials: service is constructed with `podcastIndex:
    nil`, search returns iTunes-only results, no throw.

## Acceptance criteria

- [ ] `PodcastIndexClient` signs requests correctly and decodes search +
      byfeedurl; `ITunesSearchClient` decodes search + lookup.
- [ ] `PodcastSearchService.search` runs both sources concurrently, merges by
      canonical feed key with a title+author fallback, prefers Podcast Index
      display fields, unions sources, and orders both-source hits first.
- [ ] Missing Podcast Index credentials yields a clean iTunes-only path.
- [ ] One source failing still returns the other's results; only an all-sources
      failure throws.
- [ ] Secrets are never logged; `Secrets.xcconfig.template` + `DEVELOPMENT.md`
      document the two keys.
- [ ] `make test-podcasts` green; coverage at or above floor.
- [ ] No SwiftLint / SwiftFormat warnings.

## Gotchas

- **Podcast Index `Authorization` is a request signature, not a bearer token,**
  and it changes every second (it hashes the unix time). Do not cache it; sign
  per request with the current time. SHA1 here is mandated by the API; do not
  "upgrade" it.
- **iTunes feed URLs are sometimes stale.** Apple's index lags; Podcast Index is
  usually fresher. That is exactly why Podcast Index display fields win on merge,
  and why subscribe (21-4) always re-parses the live feed rather than trusting
  index metadata.
- **Canonical-key dedupe must use the shared `FeedURL.canonicalKey`** from 21-2,
  or the same show from two sources will not merge. Do not re-implement
  normalization here.
- **Rate limits.** Podcast Index and iTunes both throttle. Debounce search input
  in the UI (phase 21-8, ~300 ms) and cancel the in-flight `search` task when the
  query changes; the service honours cancellation via
  `Task.checkCancellation()`.
- **Empty / whitespace query**: return `[]` immediately without hitting the
  network.
- **HTML in iTunes/PI descriptions** is inconsistent; treat `description` as
  plain-ish text for the result row (the detail view shows the real feed
  description).

## Handoff

Phase 21-8 calls `PodcastSearchService.search` for the results list and
`detail(for:)` + `FeedParser` for the detail view. Phase 21-4 reuses
`podcastIndexID` / `itunesCollectionID` from the chosen `PodcastSearchResult`
when it writes the `podcasts` row at subscribe time.
