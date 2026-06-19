# Phase 21-2: Podcasts - Module scaffold, feed fetch, RSS + Atom parsing

> Depends on: `phase21-0-overview.md`. This slice **creates the `Podcasts`
> module** and wires it into the workspace, then implements feed fetching
> (conditional GET) and parsing of both RSS 2.0 and Atom into the shared
> `ParsedFeed` / `ParsedEpisode` value types. No persistence and no UI here; the
> parser returns value types.
>
> Provides, for later phases: the module + its `Package.swift` + `project.yml`
> wiring + `make test-podcasts`; `PodcastsError`; the `HTTPClient` seam;
> `FeedURL.canonicalKey`; `FeedFetcher`; `FeedParser`.

## Goal

Stand up `Modules/Podcasts` and make it able to turn a feed URL into a normalized
`ParsedFeed`. Use FeedKit for the XML heavy lifting (it handles RSS 2.0 + the
iTunes and `podcast:` namespaces + Atom in one parser), and a thin normalization
layer on top so the rest of Bòcan never sees FeedKit types.

## Non-goals

- No subscribe/refresh orchestration (phase 21-4 owns that; it calls this).
- No search clients (phase 21-3, same module, separate slice).
- No artwork download (phase 21-4).

## Outcome shape

```
Modules/Podcasts/
├── Package.swift
├── Sources/Podcasts/
│   ├── PodcastsError.swift              # the module's single Error enum
│   ├── HTTPClient.swift                 # protocol + URLSession conformance (testability seam)
│   ├── FeedURL.swift                    # canonicalKey(_:) + normalization helpers
│   ├── FeedFetcher.swift               # conditional GET -> bytes + validators
│   ├── FeedParser.swift                # FeedKit -> ParsedFeed / ParsedEpisode
│   └── Models/
│       ├── ParsedFeed.swift
│       └── ParsedEpisode.swift
└── Tests/PodcastsTests/
    ├── FeedURLTests.swift
    ├── FeedParserTests.swift
    ├── FeedFetcherTests.swift
    └── Fixtures/
        ├── rss-basic.xml
        ├── rss-itunes-namespace.xml
        ├── rss-podcast-namespace.xml
        ├── atom-basic.xml
        └── rss-no-guid.xml
```

## Module scaffold

`Modules/Podcasts/Package.swift` (Swift 6, macOS 15, StrictConcurrency on, mirror
`Subsonic`'s manifest):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Podcasts",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Podcasts", targets: ["Podcasts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
        .package(path: "../Observability"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "Podcasts",
            dependencies: [
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "Observability", package: "Observability"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "PodcastsTests",
            dependencies: ["Podcasts", "Observability", "Persistence"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
```

> Persistence is a dependency now (phases 21-3 and 21-4 in this same module need
> it) even though this slice does not touch it. That keeps the manifest stable
> across the three Podcasts slices.

Wiring (do all of these in this slice, then `make generate`):

1. `project.yml`: add `Podcasts: { path: Modules/Podcasts }` to `packages:` and
   add `- package: Podcasts` to the `Bocan` target dependencies (alphabetical
   with the others). The UI dependency on Podcasts is added in phase 21-7.
2. Root `Makefile`: add a `test-podcasts` target mirroring `test-subsonic`
   (`cd Modules/Podcasts && swift test`), and add Podcasts to the `coverage-all`
   per-module floor list. If `make test` enumerates SPM modules, add it there
   too so `make tests` runs it.
3. `_standards.md`: add the `Podcasts` row to the module-dependency table (see
   `phase21-0-overview.md`).
4. `NOTICES.md`: add the FeedKit entry (FeedKit is MIT licensed). Confirm the
   exact license + version via Context7 before committing.

Verify FeedKit's current major version and Swift 6 / `Sendable` story with
Context7 (`nmdias/FeedKit`) and pin accordingly. FeedKit 9.x exposes an
`async` parse API and value-type models; if the pinned version's models are not
`Sendable`, convert to `ParsedFeed`/`ParsedEpisode` immediately inside the
parser actor and never let a FeedKit type escape the module's internals.

## `PodcastsError`

One `Error, Sendable` enum for the whole module (used by this slice and by 21-3,
21-4). Cases carry context:

```swift
public enum PodcastsError: Error, Sendable, CustomStringConvertible {
    case invalidFeedURL(String)
    case network(underlying: Error)
    case httpStatus(code: Int, url: URL)
    case feedTooLarge(bytes: Int)
    case parseFailed(url: URL, reason: String)
    case notAFeed(url: URL)                 // parsed, but no channel/items we can use
    case noEnclosure(episodeTitle: String)  // an item with no playable audio
    case searchUnavailable(source: String, reason: String)   // used by 21-3
    case notFound(feedURL: URL)             // used by 21-4
    case keychain(OSStatus, String)         // reserved if 21-3 stores PI creds in Keychain

    public var description: String { /* human-readable per case */ }
}
```

## `HTTPClient` seam

Copy the established pattern (identical to `Acoustics`/`Scrobble`
`HTTPClient.swift`) so tests can inject a `URLProtocol` stub:

```swift
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request, delegate: nil)
    }
}
```

## `FeedURL`

The single source of truth for canonicalization, used here, in 21-3 (dedupe), and
in 21-4 (uniqueness). Implement the rules from `phase21-0-overview.md` ("Feed URL
canonicalization"):

```swift
public enum FeedURL {
    /// The dedupe/identity key: scheme-less, www-less, trailing-slash-less,
    /// fragment-less, default-port-less. Host lowercased; path + query kept.
    public static func canonicalKey(_ url: URL) -> String

    /// The absolute URL to persist: https-preferred, no trailing slash, no
    /// fragment. Returns nil for inputs that are not http(s).
    public static func normalizedStorageURL(_ url: URL) -> URL?
}
```

## `FeedFetcher`

An `actor` that does a conditional GET and returns the bytes plus fresh
validators. It does not parse.

```swift
public struct FeedFetchResult: Sendable {
    public var data: Data?            // nil when notModified
    public var notModified: Bool      // server answered 304
    public var etag: String?
    public var lastModified: String?
    public var finalURL: URL          // after redirects
}

public actor FeedFetcher {
    public init(http: any HTTPClient = URLSession.shared, maxBytes: Int = 15 * 1024 * 1024)

    /// Conditional GET. Pass the stored validators (from the podcasts row) to get
    /// a 304 when unchanged. Throws PodcastsError on network/HTTP/size failures.
    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResult
}
```

Behaviour:

- `timeoutInterval` 20 s on the request.
- Send `If-None-Match: <etag>` and `If-Modified-Since: <lastModified>` when
  present. On HTTP 304, return `notModified: true` with `data: nil`.
- Set a descriptive `User-Agent` (e.g. `Bocan/<appVersion> (+https://…)`); some
  feed hosts reject empty agents.
- `Accept: application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8`.
- Enforce `maxBytes`; throw `.feedTooLarge` past it (defend against a hostile or
  broken feed). Read `Content-Length` first, but also guard the actual bytes.
- Map non-2xx (other than 304) to `.httpStatus`; map transport errors to
  `.network`.
- `try Task.checkCancellation()` before the request.
- Capture redirects: return the final URL so callers can follow a feed that has
  permanently moved (a future enhancement can persist the new URL).

## `FeedParser`

Wraps FeedKit. Input is the bytes from `FeedFetcher`; output is `ParsedFeed`.
Handle **both** RSS and Atom; FeedKit's top-level parse yields a tagged result
(rss vs atom vs json). Normalize each into the same `ParsedFeed`.

```swift
public struct FeedParser: Sendable {
    public init()
    public func parse(_ data: Data, sourceURL: URL) throws -> ParsedFeed
}
```

Normalization rules (be tolerant; real feeds are messy):

**Channel (`ParsedFeed`):**

- `title`: channel title (RSS) / feed title (Atom). Required; if missing, throw
  `.notAFeed`.
- `author`: `itunes:author`, else `managingEditor`, else `dc:creator`, else the
  Atom `author/name`.
- `description`: `itunes:summary`, else `description`, else Atom `subtitle`.
- `artworkURL`: `itunes:image/@href`, else `image/url`, else Atom `logo`.
- `link`: channel `link` (the website), not the feed URL.
- `language`, `copyright`: direct.
- `explicit`: `itunes:explicit` truthy ("yes"/"true"/"explicit").
- `categories`: `itunes:category` (+ nested) text values, de-duplicated.
- `ownerName` / `ownerEmail`: `itunes:owner`.
- `fundingURL`: `podcast:funding/@url`.

**Item (`ParsedEpisode`):**

- `guid`: item `guid` value; if absent, fall back to the **enclosure URL**
  (still stable for a given episode). Never leave it empty.
- `title`: item title; if absent, derive from `itunes:episode`/pubDate so the row
  is not blank.
- `subtitle`: `itunes:subtitle`.
- `descriptionHTML`: `content:encoded`, else `itunes:summary`, else
  `description`, else Atom `content`/`summary`. Keep the raw HTML; the UI
  sanitizes at render (phase 21-9).
- `audioURL` + `audioMIME` + `audioByteLength`: from `enclosure` (RSS) or the
  Atom `link rel="enclosure"`. **Skip items whose only enclosure is video** (mime
  starts with `video/`) or that have no audio enclosure: do not emit a
  `ParsedEpisode` for them (log at debug). If an item has multiple audio
  enclosures, take the first.
- `duration`: parse `itunes:duration`, which may be seconds (`"1832"`) or
  `H:MM:SS` / `MM:SS`. Tolerate both; nil if unparseable.
- `publishedAt`: `pubDate` (RFC 822) or Atom `published`/`updated` (RFC 3339).
  FeedKit usually gives you a `Date`; fall back to nil.
- `season` / `episodeNumber` / `episodeType`: `itunes:season` /
  `itunes:episode` / `itunes:episodeType`.
- `artworkURL`: item-level `itunes:image` when present (else nil; UI falls back to
  the show art).
- `chaptersURL` / `transcriptURL`: `podcast:chapters/@url` /
  `podcast:transcript/@url`.
- `link`: item link.
- `explicit`: item `itunes:explicit`.

Order: return episodes newest-first (sort by `publishedAt` descending, nils
last) so callers and the UI get a stable order even when a feed is unsorted.

## Context7 lookups

- `nmdias/FeedKit`: the v9 async parse entry point, the RSS vs Atom result type,
  how iTunes and `podcast:` namespace fields are exposed, and whether its models
  are `Sendable`. Pin the version. Confirm license for `NOTICES.md`.
- Apple `URLSession`: conditional GET headers (`If-None-Match`,
  `If-Modified-Since`) and 304 handling; redirect final-URL retrieval.

## Dependencies

- New SPM package: `https://github.com/nmdias/FeedKit.git` (pin via Context7,
  `from: "9.x"`). MIT licensed; add to `NOTICES.md`.
- No new Homebrew formulae, no system libraries.

## Test plan

Network is never hit. `FeedFetcher` tests use a `URLProtocol` stub or an
`HTTPClient` mock; `FeedParser` tests read checked-in fixtures.

- **FeedURLTests**: the canonicalization table cases from the overview
  (`http`/`https` equivalence, `www.` stripping, trailing slash, default ports,
  fragment, query preserved). `normalizedStorageURL` prefers https and rejects
  non-http(s).
- **FeedParserTests** (fixtures):
  - `rss-basic.xml`: title/description/items/enclosures parse; guid present.
  - `rss-itunes-namespace.xml`: author, image, explicit, duration (seconds and
    `H:MM:SS`), season/episode/type, owner.
  - `rss-podcast-namespace.xml`: `podcast:funding`, `podcast:chapters`,
    `podcast:transcript`.
  - `atom-basic.xml`: an Atom feed normalizes to the same shape (title, author,
    entries with audio links, published dates).
  - `rss-no-guid.xml`: items lacking `guid` fall back to enclosure URL; a
    video-only item is skipped; an item missing duration yields nil duration.
  - A malformed/non-feed payload throws `.parseFailed` / `.notAFeed`, not a
    crash.
- **FeedFetcherTests**: a 200 returns data + captured etag/last-modified; sending
  validators yields a 304 with `notModified == true` and `data == nil`; a 500
  throws `.httpStatus`; an oversize body throws `.feedTooLarge`; a cancelled task
  throws before issuing the request.

Author the fixtures by hand (small, deterministic); do not fetch them at test
time. Keep one real-world-ish messy feed among them (mixed namespaces, an item
with no title) so the tolerance rules are exercised.

## Acceptance criteria

- [ ] `Modules/Podcasts` builds in isolation (`cd Modules/Podcasts && swift
      build`) and via the Xcode project after `make generate`.
- [ ] `make test-podcasts` runs and is green; the target is wired into the
      `Makefile` and coverage machinery.
- [ ] `_standards.md` and `NOTICES.md` updated (Podcasts dependency row; FeedKit
      license).
- [ ] `FeedURL.canonicalKey` satisfies every row of the overview's
      canonicalization table.
- [ ] `FeedParser` turns RSS 2.0 (plain, iTunes-namespaced, podcast-namespaced)
      and Atom into a uniform `ParsedFeed`; guid falls back to enclosure URL;
      video-only items are skipped; durations in both formats parse.
- [ ] `FeedFetcher` does conditional GET, honours 304, enforces the size cap, and
      respects cancellation. No FeedKit type escapes the module's public API.
- [ ] No SwiftLint / SwiftFormat warnings; module coverage at or above floor.

## Gotchas

- **FeedKit is a third-party boundary.** If its models are not `Sendable` under
  the pinned version, do the FeedKit parse on a non-actor function and convert to
  `ParsedFeed` before returning; do not store FeedKit types in actor state. Add a
  one-line `// third-party boundary` comment if a `@preconcurrency import` is
  unavoidable (per `_standards.md`).
- **`itunes:duration` is wildly inconsistent.** Seconds, `MM:SS`, `H:MM:SS`,
  sometimes with stray decimals. Parse defensively; never trust it for seek math
  later (the engine's real decoded duration wins once playback starts).
- **GUIDs are not globally unique.** They are unique per feed at best, and some
  feeds reuse or rotate them. The `(podcast_id, guid)` composite is the identity;
  the enclosure-URL fallback covers feeds with no guid at all.
- **`isPermaLink="true"` guids** are URLs; that is fine, store them verbatim.
- **Date parsing.** `pubDate` is RFC 822 with quirks (missing leading zeros,
  non-standard zones). Let FeedKit parse it; only fall back to nil, never crash.
- **Redirects.** A feed often 301s to a new host (hosting migrations). Capture
  `finalURL` now; persisting the moved URL is a 21-4 nicety, but losing the
  redirect means every refresh pays the redirect again.
- **Do not log full feed bodies.** They can be large; log `url`, byte count, item
  count at debug.

## Handoff

Phase 21-3 adds the search clients to this module. Phase 21-4's `PodcastService`
calls `FeedFetcher` + `FeedParser` to subscribe and refresh, mapping `ParsedFeed`
to the `Podcast` / `PodcastEpisode` records from phase 21-1.
