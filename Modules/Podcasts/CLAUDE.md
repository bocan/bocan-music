# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Podcasts` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`. UI for podcasts lives in the `UI` module; the App layer wires the seams (see below).

## What this module owns

Subscriptions, feed fetch/parse, search, downloads, and the playback-state bridge for podcasts. It sits beside the other mid-tier modules (depends only on `Observability` and `Persistence`) and never imports `UI`.

- **`PodcastService`** (an `actor`) is the single public facade: subscribe / unsubscribe / refresh, the playback-state read/write bridge, observation streams, OPML import/export, per-show settings, chapters, and transcripts. Almost everything above this module calls through it. An in-actor `idCache` maps a normalized feed URL to its row id so the ~5 s position write-back never hits the DB to resolve an id.
- **Feed pipeline:** `FeedFetcher` (actor) does the network fetch with a conditional GET (ETag / Last-Modified), a size cap, and the shared `UserAgent`; `FeedParser` wraps FeedKit and normalizes RSS/Atom into the module's own value types (`Models/ParsedFeed.swift`, `Models/ParsedEpisode.swift`); `Mapping/ParsedFeed+Records.swift` maps those to `Persistence` records. `FeedRefreshScheduler` (actor) drives `refreshAllStale` in the background.
- **`Parsing/PodcastNamespaceSupplement`** is an `XMLParser`-backed best-effort pass that fills the Podcasting 2.0 tags FeedKit 10.4.0 does not model (`podcast:funding`, `podcast:chapters`). `Chapters/` (Podcasting 2.0 JSON chapters) and `Transcripts/` (cache-first transcript fetch) are the other supplementary fetchers.
- **`OPML/`** is a dedicated reader (`XMLParser`) and writer (string building) for subscription import/export, peers to `FeedParser` (FeedKit does not model OPML).
- **`Search/`** is the dual-index search: `PodcastIndexClient` (HMAC-SHA1 auth in `PodcastIndexAuth`), `ITunesSearchClient`, merged and deduped by `PodcastSearchService`. `FeedURL.canonicalKey` is the single source of truth for feed identity (dedupe + subscription uniqueness).
- **`Downloads/`** is episode download + storage management (`EpisodeDownloadManager`, `DownloadStore`, `AutoDownloadCoordinator`); `PodcastArtworkCache` caches show art. `HTTPClient` is the `URLSession` seam every networked type takes for testability. `PodcastsError` is the module's single error enum. `PodcastPlayback` holds shared progress thresholds.

## Things easy to get wrong

- **Refresh must never write to `podcast_episode_state`.** Content rows (`podcast_episodes`) and user state (`podcast_episode_state`) are separate tables on purpose; refresh upserts content only. The headline test in `PodcastServiceTests` guards this; the design-invariant comment is at the top of `PodcastService`.
- **`upsertByFeedURL` preserves user-owned podcast fields** (`id`, `addedAt`, `subscribed`, `autoDownload`, `sortIndex`, `playbackSpeed`, `episodeSort`, `retentionLimit`, `artworkPath`) and refreshes everything else from the feed (including the feed-derived `showType` and `artworkURL`). `artworkPath` is the locally cached cover-art file path, not feed content; the parse never carries it, so a refresh that did not preserve it would wipe the cached image (and `PodcastService.refresh` only re-downloads art on a URL change, so it would stay blank). `PodcastService.ensureArtworkCached` is the self-heal: it re-downloads when the cached file is missing, on both the 200 and 304 paths. When you add a user-owned column, add it to that preservation copy in `PodcastRepository` (in `Persistence`).
- **FeedKit's format sniffer inspects only the first 128 bytes.** A feed with an `<?xml-stylesheet?>` PI (or long prolog) pushes the `<rss>` / `<feed>` root past that window and FeedKit throws `unknownFeedFormat`. `FeedParser.parse` retries once with the prolog stripped (`feedDataWithStrippedProlog`); keep that fallback if you touch the parse path.
- **FeedKit 10.4.0's `podcast:` namespace only covers `guid` + `transcript`.** `funding` and `chapters` come from `PodcastNamespaceSupplement`, which reads the original (unstripped) bytes via `XMLParser`. Per the root `CLAUDE.md` Context7 rule: watch FeedKit for official support and prefer it when it lands, but don't reintroduce a regression by removing the supplement until then.
- **`AVAudioFile` snapshot semantics live one module up** (`AudioEngine`), but the consequence reaches here: `FeedFetcher` waits for the full body and enforces `maxBytes` (currently 50 MB) before handing data to the parser. Large back-catalogue feeds re-download in full on every refresh; there is no partial fetch.
- **Networked types take an `HTTPClient`, never a bare `URLSession`.** This is the test seam. New fetchers must accept `http: any HTTPClient = URLSession.shared` and send the shared `Observability.UserAgent.string` (ASCII; HTTP headers are US-ASCII).
- **No `UI` types here.** The UI declares the seam protocols (`PodcastActions`, `PodcastLibraryDataSource`, ...) in the `UI` module and the App layer adapts them over `PodcastService`; this module exposes plain `Sendable` value types (`PodcastSearchResult`, `Chapter`, `OPMLImportSummary`, ...). Do not add a reverse dependency.
- **`PodcastSearchResult` / capability snapshots are persisted per server**; search credentials are user-supplied. Keep secrets out of logs (the `Observability` redaction covers `sensitiveKeys`, but don't widen what you log).

## Testing

Run `make test-podcasts` from the repo root before committing any change to this module (it runs `swift test` with code coverage and sets the FFmpeg-free env this module needs). If you first ran a single `swift test --filter`, run `make test-podcasts` last so the full module suite is the final gate.

- **Tests must not hit the network.** Inject the shared `MockHTTPClient` (defined in `Tests/PodcastsTests/FeedFetcherTests.swift`, reused across the suite) and configure its `handler` per request. `PodcastServiceTests` shows the canonical `TestBed` that wires an in-memory `Database` + a `PodcastService` with separate feed / artwork / transcript mocks.
- **Fixtures are checked in** under `Tests/PodcastsTests/Fixtures/` and copied via `resources: [.copy("Fixtures")]` in `Package.swift`; load them with `Bundle.module.url(forResource:withExtension:subdirectory:"Fixtures")`. Add new fixtures there rather than generating bytes at test time.
- **Adding a source file to a path-dependency (e.g. a new `Persistence` migration) can be missed by a stale SPM build plan**, surfacing as "cannot find `<symbol>` in scope" when building this package. `swift package clean` under `Modules/Podcasts` forces a re-glob.
