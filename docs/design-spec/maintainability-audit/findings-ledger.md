# Maintainability Audit -- Findings Ledger

The durable record of the audit. **Every cluster considered gets a row**, in all
four outcomes, so nothing is silently dropped and no future audit re-litigates a
decision already made. Append as you go; never delete a row.

Read the method and the decision rubric in [README.md](README.md) first.

## How to fill this in

- **ID**: `S<session>-<n>`, e.g. `S1-3` for the third cluster considered in
  Session 1.
- **Location(s)**: `file:line` for each copy, or a directory + pattern if many.
- **Kind**: from the taxonomy (near-duplicate-fn, copy-paste-block,
  parallel-types, boilerplate-wrapper, repeated-literal, test-scaffolding).
- **Copies / lines**: how many copies and roughly how many lines each, plus the
  normalized-diff overlap if measured (e.g. "3x ~12 lines, 90% identical").
- **Decision**: `consolidated` | `tolerated` | `rejected` | `deferred`.
- **Rationale**: one line. For `consolidated`, name the new shared symbol and the
  before/after line delta. For `rejected`, name which rubric step killed it
  (break-even, coupling, config-bag, test-churn). For `deferred`, name the target
  (Session 10 / cross-module).
- **Commit**: short hash, for `consolidated` rows.

## Shared surface (grows bottom-up)

As each session confirms or creates a reusable helper, list it here so higher
sessions dedup against it instead of re-copying. Format: `symbol -- module -- what it does`.

| Symbol | Module | Purpose | Since |
|--------|--------|---------|-------|
| `Database.fetchOne(_:id:entity:)` | Persistence | Fetch a record by primary key or throw `PersistenceError.notFound`. Module-internal; use from any repository's `fetch(id:)` instead of re-rolling the guard/throw body. | S1 |
| `SQL.escapeFTSTerm` / `SQL.escapeLIKETerm` | Persistence | FTS5 MATCH prefix-token builder and LIKE operand escaper. Confirmed single-source (module-internal); do not re-implement inline. | S1 (pre-existing) |
| `CoverArtCache` (`persist` / `sweep`) | Library | Single-source cover-art on-disk scheme: path `<cacheRoot>/<sha256[0..<2]>/<sha256>.<ext>`, LRU sweep re-derives the hash from the filename. sha256 itself comes from `Metadata.ExtractedCoverArt.sha256`. UI/others read `cover_art.path`; never re-derive the path or hash. | S3 (pre-existing) |
| `M3UReader` (`decode`/`splitLines`/`resolveURL`) + `M3UWriter` (`renderPath`/`relativePath`) | Library | Shared playlist path-resolution and text-decode helpers; PLS/XSPF readers and writers already route through these. Confirmed single-source for playlist path/relative-path math. | S3 (pre-existing) |
| `LastFmCompatibleTransport` | Scrobble | Last.fm-compatible HTTP + `api_sig` signing + error-code mapping engine; Last.fm (and future signed providers) delegate to it. Confirmed single-source. | S4 (pre-existing) |
| `ListenBrainzCompatibleTransport` | Scrobble | ListenBrainz-compatible `submit-listens` payload builder + POST/`ScrobbleError`-mapping engine; ListenBrainz and Rocksky delegate to it. Any future ListenBrainz-protocol provider should too. | S4 |
| `EmptyState` / `LoadingState` / `ErrorState` | UI/Common | The single source for the three placeholder states (symbol + title + optional message + optional action). **Sessions 7-9: use these; do not hand-roll.** `ErrorState` has 0 call sites today (see S6-6). | S6 (pre-existing) |
| `Formatters` | UI/Common | `duration`/`bitrate`/`fileSize`/`stars`/`shortDate` display formatting. Single-source for UI value formatting; do not re-create `ByteCountFormatter`/`DateFormatter` inline. (Cross-module duration/byte formatting is an S10 candidate.) | S6 (pre-existing) |
| `CollectionCard` / `CollectionCardGrid` / `CollectionModeToggle` / `CoverMosaicGenerator` | UI/Components | Phase-23 reusable card-grid components. `CollectionCardGrid` also carries the #349 scroll-offset snapshot/restore. **Session 7: dedup the Browse grids against these** (see S6-5/S6-6). | S6 (pre-existing) |
| `SortMenu` / `SortMenuOption` | UI/Browse | Shared sort-order dropdown; a VM's sort enum adopts `SortMenuOption` (localized `displayName`) to populate it. Carries menu display only, not the UserDefaults persistence (see S6-2). | S6 (pre-existing) |
| `View.loadErrorAlert(_:message:)` | UI/Common | One-button OK error alert bound to a view model's optional `errorMessage`. Use for any load-and-show surface (Subsonic browse views use it; Sessions 8-9 should too) instead of hand-building the `isPresented` Binding. | S7 |
| `SubsonicSongRow` | UI/Browse/Subsonic | Shared Subsonic song cell (cover + title + subtitle). Already reused across Bookmarks/Starred/etc.; the seed's "share the cell" is satisfied. | S7 (pre-existing) |

## Findings

| ID | Session / scope | Location(s) | Kind | Copies / lines | Decision | Rationale | Commit |
|----|-----------------|-------------|------|----------------|----------|-----------|--------|
| _example_ | S0 / demo | `A.swift:10`, `B.swift:22` | near-duplicate-fn | 2x ~8 lines, 95% | tolerated | rule of three: only 2 copies, low churn risk | -- |
| S1-1 | S1 / Persistence repos | `ArtistRepository.fetch(id:)`, `AlbumRepository`, `LibraryRootRepository`, `PlaylistRepository`, `TrackRepository`, `EpisodeRepository`, `PodcastRepository` | near-duplicate-fn | 7x 8-9 lines, ~90% (only record type + entity string differ) | consolidated | Extracted `Database.fetchOne(_:id:entity:)` (generic over `FetchableRecord & TableRecord`). 3-param interface, no closures/config bag; call sites drop to one line; public `fetch(id:)` signatures + entity strings unchanged (no test churn). Net -17 lines. | `083de5a` |
| S1-2 | S1 / Persistence repos | `Repositories/*.swift` (~164 `database.read`/`write` closure sites) | boilerplate-wrapper | 20 repos, highly varied method sets | rejected | Seeded generic-`Repository<Record>` base: method sets diverge sharply (Track has 32 sites w/ FTS + custom queries; most repos 2-6). A base could only carry a thin, inconsistent slice while forcing a generic supertype on all -- config-bag/coupling trap. The one genuine win inside this surface is S1-1. | -- |
| S1-3 | S1 / Persistence repos | every `Repositories/*.swift` struct header | copy-paste-block | 16x 3 lines (`private let database` + `private let log` + `init`) | rejected | Sharing forces a common base type to remove 3 trivial, idiomatic lines; couples all repos to it for no behavior. Break-even + coupling. | -- |
| S1-4 | S1 / Persistence repos | `fetchAll()` in Album/Artist/LibraryRoot/Playlist/Track/Subsonic | near-duplicate-fn | ~6x 3 lines | tolerated | The `ORDER BY` clause is the payload and differs per repo; parameterizing it makes the call as long as the inline body (rubric step 3/4). | -- |
| S1-5 | S1 / Persistence repos | `AlbumRepository.count():156`, `TrackRepository.count():204` | near-duplicate-fn | 2x 2 lines | tolerated | Only two plain `fetchCount(db)` wrappers; the rest are filtered counts. Below rule of three. | -- |
| S1-6 | S1 / Persistence records | `Records/*.swift` `CodingKeys` | parallel-types | 15 records | tolerated | Each camelCase->snake_case map is a unique per-type schema, not structural duplication. A global `.convertFromSnakeCase` strategy would be a behavior change (out of scope) and risks columns that don't follow the rule. | -- |
| S1-7 | S1 / Persistence records | `Track.swift` `init(row:)` | boilerplate-wrapper | 1x | tolerated | Only Track hand-writes `init(row:)`; single occurrence, nothing to dedup. | -- |
| S1-8 | S1 / Persistence SQL | `Internal/SQL.swift` FTS builders | repeated-literal | 2 identical (`artistsFTSQuery`, `albumsFTSQuery`) + 1 variant (`tracksFTSQuery`) | tolerated | Only two are truly identical-shape; parameterizing the table name means interpolating SQL identifiers into the string and trading readable literal SQL. Rule of three not met for the clean pair. | -- |
| S1-9 | S1 / Persistence migrations | `Migrations/M0NN_*.swift` + `Migrator.make()` | copy-paste-block | 33x `register(in:)` shape | tolerated | Migration bodies are unique SQL and append-only/immutable; the `make()` list is an ordered manifest, clearest explicit. Seed forbids touching shipped bodies. | -- |
| S1-10 | S1 / Observability | `AppLogger.swift` trace/debug/info/notice/warning/error/fault | near-duplicate-fn | 7x 5 lines, ~90% | rejected | `os.Logger` has no behavior-preserving single `log(level:)` (its `OSLogType` has 5 cases, not 7; trace/notice/warning would remap). A sink-closure helper is ~break-even and adds a closure per call on the foundational logging API. Step 4: prefer the duplication. | -- |
| S2-1 | S2 / AudioEngine DSP | `CrossfeedUnit.swift` (`CrossfeedAudioUnit`), `StereoExpanderUnit.swift` (`StereoExpanderAudioUnit`) | copy-paste-block | 2x ~60 lines near-identical plumbing (setupBuses, param-event render loop, registration, init/deinit, bus arrays) | rejected | Only two custom `AUAudioUnit` subclasses (rule of three). Folding the shared render/setup into a base risks the RT-safety contract (render block captures only a raw pointer -- no allocations/locks/witness dispatch) and makes each AU no longer self-auditable for real-time safety. The one non-RT slice safe to share (`setupBuses`) is break-even. | -- |
| S2-2 | S2 / AudioEngine Decoder | `AVFoundationDecoder.swift` (~100 lines), `FFmpegDecoder.swift` (~469) | parallel-types | 2 impls behind the `Decoder` protocol | tolerated | Twins by necessity (seed's caution): they share only the protocol. AVAudioFile vs the FFmpeg C-API + RAII path diverge entirely; nothing but the protocol is common. | -- |
| S2-3 | S2 / AudioEngine DSP | `BassBoostUnit`, `EQUnit`, `GainStage`, `LimiterUnit` preamble; `bypass` get/set (EQ/Crossfeed/StereoExpander); `AudioUnitReset` in BassBoost/EQ | boilerplate-wrapper | 3-4x 1-3 line idioms | tolerated | Each wraps a different Apple node type (AVAudioUnitEQ / AVAudioUnitEffect / AVAudioMixerNode); a shared protocol would couple independent wrappers for no net line reduction on 1-3 line members. | -- |
| S2-4 | S2 / AudioEngine DSP (cross-module) | `DSPChain.swift:326` private `clamped(to:)` + ~5 inline `max(_,min(_,_))` in DSP units/AudioEngine; ~46 sites repo-wide (AudioEngine 8, Library 5, Playback 3, UI 30) | near-duplicate-fn | 1 private helper + ~46 inline re-impls | deferred | Cross-module micro-helper. Hoist a single `clamped(to:)` to Observability (DAG floor) and dedup repo-wide in Session 10; an AudioEngine-only version now would be redone there. Target: **Session 10**. | -- |
| S2-5 | S2 / Acoustics (cross-module) | `AcoustIDClient.lookup`, `MusicBrainzClient.fetchRecording` | copy-paste-block | 2x ~25 lines (rateLimiter.wait + checkCancellation + build request + send/networkError-map + status/rate-limit map + JSONDecode/invalidResponse-map) | deferred | Seed's explicit instruction: this HTTP-request/decode/error-map shape recurs in Scrobble (S4) and Subsonic (S5). Design one reusable client helper across all three in Session 10, not upward from here now. Target: **Session 10**. | -- |
| S2-6 | S2 / Metadata | `TagReader.read` (BOCTags->TrackTags), `TagWriter.buildBOCTags` (TrackTags->BOCTags) | parallel-types | 2x ~40-field maps, inverse | tolerated | Inverse mappings that must co-evolve (a new tag needs both arms) but share no code: write uses nil->0 / .nan sentinels, read uses >0->nil unwrapping. Not duplication. | -- |
| S2-7 | S2 / AudioEngine | `BufferPump.swift:199`, `ReplayGainAnalyzer.swift:87` `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` | near-duplicate-fn | 2x 1 line | tolerated | Two allocation sites in different formats/contexts, below rule of three. Format conversion is already single-sourced in `Internal/FormatConverter.swift`. | -- |
| S3-1 | S3 / Library scan | `LibraryScanner.scan`/`scanSingleFile` -> `ScanCoordinator.importOne` -> `TrackImporter.importTrack` | boilerplate-wrapper | 1 core, N entry points | tolerated | Seed's #1 concern is already addressed: full-scan, incremental and single-file/add-files all funnel through one `importOne` -> `importTrack`. No parallel track-construction to fold. | -- |
| S3-2 | S3 / Library | `TrackImporter.importTrack:52-107`, `EditTransaction:...309-345` (artist/albumArtist/album `findOrCreate` + same-artist optimization + year propagation) | near-duplicate-fn | 2x ~15 lines | tolerated | Seed sets the bar at 3+ copies; only 2 exist, and their surrounding context diverges hard (tags + `extendedTags` multi-value + compilation->Various Artists vs patch + current-row fallback). A bridging helper would need ~5 params (config-bag). | -- |
| S3-3 | S3 / Library PlaylistIO | `M3UWriter`, `PLSWriter`, `XSPFWriter` | parallel-types | 3 writers | tolerated | Already well-factored: PLS and XSPF call `M3UWriter.renderPath`/`relativePath`; each `write` emits a genuinely different format. Nothing left to share. | -- |
| S3-4 | S3 / Library PlaylistIO | `M3UReader.decode` (byte BOM strip + utf8/cp1252/isoLatin1) vs `PLSReader.stripBOM` + inline encoding chain | near-duplicate-fn | 2x ~10 lines | tolerated | 2 copies; routing PLS through `M3UReader.decode` would change its `.unreadable` reason string (a user-visible behavior change, out of scope) for a ~6-line save. Readers already share `splitLines`/`resolveURL`. | -- |
| S3-5 | S3 / Library SmartPlaylists | `Comparator.swift`, `Field.swift` (`init(rawValue:)` + `rawValue` + `allCases` + singleValueContainer Codable) | parallel-types | 2x ~50-line switches + 2x identical 10-line Codable block | tolerated | 2 conformers (below rule of three). The `.unknown(String)` forward-compat case forbids a `String` raw enum; the per-enum switches are unique content; the exhaustive `switch` is safer than a lookup table. Only the 10-line Codable block is truly shareable -- revisit with a `RawStringCodable` protocol if a 3rd such enum appears. | -- |
| S3-6 | S3 / Library SmartPlaylists | `FieldDefinitions.table` (Field -> SQL column/join/comparators) | repeated-literal | 1 table, ~30 fields | tolerated | Already the consolidated form: a single table-driven registry, not N inline branches. Exemplary; nothing to do. | -- |
| S3-7 | S3 / Library | `CoverArtCache` path/hash scheme | repeated-literal | single-source | tolerated | Exit-criterion check: the `<sha256[0..<2]>/<sha256>.<ext>` scheme lives in one `persist`; `sweep` re-derives the hash from the filename. Recorded in shared surface. | -- |
| S3-8 | S3 / Library | `ConflictResolver.resolve` | near-duplicate-fn | 1x 30 lines | tolerated | v1 policy is a single "user-edited wins" decision; no compare-old-vs-new field ladder exists to compress. | -- |
| S3-9 | S3 / Library CoverArt (cross-module) | `CoverArt/MusicBrainzClient.swift` (140), `CoverArt/RateLimiter.swift` vs `Acoustics/MusicBrainzClient.swift` (94), `Acoustics/RateLimiter.swift` | parallel-types | 2 MB clients (diverge: cover-art release-group search vs recording lookup); 2 rate-limiters (same concept, ~different impl) | deferred | Cross-module siblings, not copies. Fold into the Session 10 HTTP-client + rate-limiter cross-module work (with Scrobble/Subsonic). Target: **Session 10**. | -- |
| S3-10 | S3 / Library | `FSWatcher.swift` (FSEvents) | boilerplate-wrapper | 1 | tolerated | Single file-watcher; no second debounce/coalesce implementation to dedup against. | -- |
| S4-1 | S4 / Scrobble providers | `ListenBrainzProvider` + `RockskyProvider` (`buildPayload`, `post`) | parallel-types | 2x: `buildPayload` byte-identical (~20 lines); `post` ~35 lines differing only in one log line | consolidated | Rocksky is ListenBrainz-compatible *by definition* -- the payload must stay in lockstep (rule-of-three lockstep exception), and the module already set the precedent with `LastFmCompatibleTransport`. Extracted `ListenBrainzCompatibleTransport`; providers keep their own method logic/logging and distinct love/auth. Shares the skeleton, not the bodies (seed's ask). Net -25 lines. | `889d78d` |
| S4-2 | S4 / Scrobble providers | `LastFmProvider` request/sign/parse/error-map | parallel-types | already factored | tolerated | Already consolidated: `LastFmProvider` delegates all HTTP/signing/error-mapping to `LastFmCompatibleTransport`. This was the precedent for S4-1. | -- |
| S4-3 | S4 / Scrobble | offline queue enqueue/flush/retry (`ScrobbleQueueWorker`, `ScrobbleQueueRepository`, `RetryPolicy`) | boilerplate-wrapper | single-source | tolerated | Seed check: the queue/retry loop is centralized in the worker; providers only build+submit and return `SubmissionResult`. Not re-implemented per provider. | -- |
| S4-4 | S4 / Scrobble (cross-module) | provider transports' generic request/decode/error-map vs Acoustics (S2-5) / Subsonic | copy-paste-block | the generic HTTP-client layer beneath the protocol-specific transports | deferred | The two Scrobble transports are protocol-specific (Last.fm signing; ListenBrainz payload) and correctly stay distinct. The *generic* send/status/decode primitive beneath them is the cross-module candidate; fold with Acoustics/Subsonic in Session 10. Target: **Session 10**. | -- |
| S4-5 | S4 / Playback | `GaplessScheduler` vs `CrossfadeScheduler` | parallel-types | 2x ~200 lines, ~304 diff lines (mostly distinct) | tolerated | Distinct timing models (poll-and-preschedule vs volume-ramp handoff); no shared code reference between them. Seed: keep the timing math distinct. Format-compat check is already shared via `FormatBridge`. | -- |
| S4-6 | S4 / Playback | `PlayableSource` per-case accessors + discriminated `Codable` | parallel-types | 4 accessors + 1 encode/decode switch | tolerated | Canonical discriminated-enum shape; each accessor extracts a different associated value (can't share). Switch-over-source appears only in the enum itself and `QueuePlayer`, not repeated across files. | -- |
| S4-7 | S4 / Playback | `FisherYatesShuffle` vs `SmartShuffle` | parallel-types | 2 strategies behind `ShuffleStrategy` | tolerated | Genuinely different algorithms behind one protocol (strategy pattern); nothing to fold. | -- |
| S5-1 | S5 / Subsonic | `SubsonicService` endpoint methods (getArtists/getAlbum/search3/star/scrobble/… + the 3 capability-gated) | boilerplate-wrapper | 20x ~8 lines, ~identical (`requireClient` -> call client -> `catch SwiftSonicError { throw .transport }`) | consolidated | Added `withClient(_:_:)` and `withCapabilityGatedClient(_:feature:_:)`. 20 endpoints collapse to one delegating line each; public signatures + behavior unchanged. Not the cross-module HTTP shape -- SwiftSonic owns the actual HTTP; this is the SwiftSonic->Subsonic error-map wrapper. Net -61 lines. | `cd7b4fb` |
| S5-2 | S5 / Subsonic | `loadCapabilities`, `refreshCapabilities` | boilerplate-wrapper | 2x, complex bodies | tolerated | Kept explicit: each has an early-return cache check before the client call plus multi-step persist/compare/yield; forcing them through `withClient` would bury a 25-line closure and obscure the early return. | -- |
| S5-3 | S5 / Subsonic+SyncServer+Podcasts (cross-module) | `HTTPClient` protocol + request/decode/error-map (Acoustics, Scrobble, Podcasts identical; Library) | boilerplate-wrapper | protocol byte-identical across 3 modules; send/status/decode repeated per client | deferred | The third+ sighting; concrete S10 proposal recorded below. Subsonic excluded (delegates HTTP to SwiftSonic). Target: **Session 10**. | -- |
| S5-4 | S5 / Scrobble+Subsonic+SyncServer (cross-module) | `SecItem` Keychain access (`Scrobble/Credentials`, `Subsonic/SubsonicServerStore`, `SyncServer/IdentityStore`) | copy-paste-block | 3x SecItemAdd/CopyMatching/Delete query-dict + OSStatus mapping | deferred | Seed's "one helper or several?" -> several. Scrobble+Subsonic store generic passwords (closest pair); SyncServer stores a `SecKey`+certificate (distinct). Concrete S10 proposal below. Target: **Session 10**. | -- |
| S5-5 | S5 / SyncServer | `SelfSignedCert` (P-256 key + cert), `IdentityStore` | boilerplate-wrapper | single-source | tolerated | Cert/key derivation is centralized in `SelfSignedCert.generate`/`makeCertificate`; `IdentityStore` delegates to it. No repeated derivation. | -- |
| S5-6 | S5 / SyncServer | `Http/` route handlers + `HttpResponse` | boilerplate-wrapper | factories centralize | tolerated | Response building goes through `HttpResponse` static factories (`.json`, 204, …); only ~6 raw `HttpResponse(` sites, mostly inside those factories. Routes already share. | -- |
| S5-7 | S5 / Podcasts | `Mapping/ParsedFeed+Records` feed field-mapping | boilerplate-wrapper | single-source | tolerated | Seed check: field-mapping lives in one file. OPML carries only subscription URLs (no field map); refresh and import both route through the same mapping + `upsertByFeedURL`. | -- |
| S5-8 | S5 / Podcasts vs Scrobble (cross-module) | `Downloads/EpisodeDownloadManager` vs `ScrobbleQueueWorker`/`RetryPolicy` | parallel-types | not near-identical | tolerated | Seed check: not twins. Downloads drive `URLSession` download tasks (bytes/progress/resume); the scrobble queue is a DB-backed pending-row retry loop with backoff. No shared retry/backoff to fold. | -- |
| S6-1 | S6 / UI ViewModels | `AlbumsViewModel`/`ArtistsViewModel`/`TracksViewModel` `load()` bodies (`isLoading = true` / do-catch-log / `isLoading = false`) | boilerplate-wrapper | ~12 sites in the spine (25+ repo-wide) | rejected | Seed's own over-abstraction warning. A cross-VM `withLoading` needs a protocol spanning two observation models (`@Observable` vs `ObservableObject`) plus a settable `isLoading` on observation-sensitive state (VMs carry delicate coalescing/observation-cycle comments -- behavior risk). `AlbumsViewModel.loadFiltered` already shares where it paid off. | -- |
| S6-2 | S6 / UI ViewModels | sort-order UserDefaults plumbing (`sortOrderKey` + init-read + `setSortOrder`) in `Albums`/`Artists`/`Podcasts` VMs | near-duplicate-fn | 3x | tolerated | `SortMenu`/`SortMenuOption` already carry the menu display. The only VM-agnostic slice is the 2 UserDefaults get/set lines (break-even); `setSortOrder`'s guard + re-sort is per-VM (albums vs artists vs podcasts). A property wrapper would fight `@Published`. | -- |
| S6-3 | S6 / UI AppRoot | `CrashRecoveryBanner`, `DiagnosticsConsentBanner` shared `.safeAreaInset` chrome | copy-paste-block | 2x ~30 lines identical chrome | rejected | Extracted a shared `InsetBanner` and **measured it: net +18 lines** (the reusable view + its doc offsets the two call sites' savings), for a 5-param + `ViewBuilder` + `AnyShapeStyle` interface at only 2 copies with no lockstep. Rubric Step 4 (break-even + indirection -> prefer duplication). Reverted; build/test-ui/lint were green with it, so it's viable if a 3rd banner ever appears. | -- |
| S6-4 | S6 / UI Common | `EmptyState`, `LoadingState`, `ErrorState` | parallel-types | single-source | tolerated | Confirmed the single source for the three placeholder states (EmptyState 11 call sites, LoadingState 9). Recorded in shared surface for S7-9. | -- |
| S6-5 | S6 / UI (spans Browse) | #349 scroll-offset snapshot+restore: `CollectionCardGrid` (canonical) vs hand-rolled in `AlbumsGridView`/`ArtistsView` | copy-paste-block | 3x (`@State scrollPosition` + `.onScrollGeometryChange` + `scrollTo(y:)` restore) | deferred | Real 3-copy dup, but 2 copies live in `Browse/` (Session 7's scope). Extract a `scrollOffsetRestore(_ offset:)` ViewModifier and dedup all three together in S7. Target: **Session 7**. | -- |
| S6-6 | S6 / UI Components | `CollectionModeToggle` (0 call sites), `ErrorState` (0 call sites) | boilerplate-wrapper | possibly shadowed | deferred | Both reusable components appear unused -- likely shadowed by inline copies in `Browse/` views (the seed's "not shadowed by older inline copies" check). S7 should confirm and dedup the inline copies against these. Target: **Session 7**. | -- |
| S6-7 | S6 / UI Common (cross-module) | `Formatters` (`duration`/`fileSize`/…) | repeated-literal | single-source in UI | tolerated | Single-source for UI display formatting. Note: `DateComponentsFormatter`/`ByteCountFormatter`/`%02d:%02d` duration formatting recurs in lower modules too -- a cross-module shared-formatter candidate for **Session 10** (per the toolkit's ~13-file grep). | -- |
| S7-1 | S7 / UI Browse/Subsonic | error alert in 11 Subsonic browse views (12 sites): `SubsonicStarred`/`Bookmarks`/`Albums`/`Artists`/`Genres`/`Songs`/`Podcasts`/`Playlists`(x2)/`InternetRadio`/`AlbumDetail`/`ArtistDetail` | copy-paste-block | 12x ~9 lines byte-identical (only the title differs) | consolidated | Extracted `View.loadErrorAlert(_:message:)` in Common. The config-free leaf the seed calls for: a title + a `Binding<String?>`. Each site -> one line; titles + behavior unchanged. Net -69 lines. | `c82de1a` |
| S7-2 | S7 / UI Browse/Subsonic | Refresh toolbar (7 views: `arrow.clockwise` primary-action button) | boilerplate-wrapper | 7x ~7 lines | tolerated | Not config-free: the action varies (`vm.load()` vs `vm.refresh()`), the `disabled` condition varies (`isLoading` vs `isLoading || isSearching`), and some add a `.help`. A shared helper needs a config bag + hits Task-closure `@Sendable` friction. Share-leaves test fails. | -- |
| S7-3 | S7 / UI Browse/Subsonic | `SubsonicBrowseViewModel` `load()` shape (guard/isLoading/defer + do-catch-log-map) across 11 VMs | boilerplate-wrapper | 11x ~12 lines | tolerated | A `SubsonicLoadable` protocol + default `load` needs `isLoading` settable at protocol level, but it is `@Published public private(set)` -- satisfying `{ get set }` means relaxing to `public var`, a public-API change (out of scope). The per-VM body (which property, post-processing) also differs. | -- |
| S7-4 | S7 / UI (spans spine) | #349 scroll-offset restore: `CollectionCardGrid` vs `AlbumsGridView` vs `ArtistsView` | copy-paste-block | 3x | tolerated | Overturns S6-5 on inspection. The config-free slice is 2-3 modifier lines (`.scrollPosition` + `.onScrollGeometryChange`) = break-even; the persisted-offset source (`@Binding` vs `vm.gridScrollOffset`), the restore trigger (onAppear vs root `onChange` -- ArtistsView deliberately differs for its conditional strip), and the snapshot call site all vary. `CollectionCardGrid` is already the shared component for new card grids. | -- |
| S7-5 | S7 / UI Browse | `TrackTableCoordinator` (500) vs `SubsonicSongTableCoordinator` (325) | parallel-types | 597 diff lines (normalized) | tolerated | Both are `NSViewRepresentable`/`NSTableView` coordinators but the logic diverges hard (local: sort/columns/drag/context-menu/selection; Subsonic: remote data source + async cover art). Sharing the leaf `SubsonicSongRow` is already done; fusing the coordinators would couple two complex, genuinely different controllers. | -- |
| S7-6 | S7 / UI (S6-6 follow-up) | `CollectionModeToggle` (0 refs anywhere), `ErrorState` (0 call sites) | boilerplate-wrapper | dead / superseded | rejected | Resolves S6-6: neither is shadowed by inline copies. `CollectionModeToggle` is dead code (0 references); `ErrorState` is unused because Browse surfaces errors via `.alert` (see S7-1) and empties via SwiftUI's `ContentUnavailableView`. Dead-code/consistency cleanup is out of the dedup audit's scope; noted for a future tidy. | -- |

<!--
Append rows below per session. Keep the example row at the top as the format
reference. Do not delete rows once written.
-->

## Session 10 concrete proposals (cross-module)

Recorded here so Session 10 starts from a design, not a re-investigation.

### HTTP client (S2-5, S3-9, S4-4, S5-3, S5-8's clients)
- **Home:** a new leaf module `Networking` (Foundation-only, sits at the DAG floor
  beside `Observability`), imported by Acoustics/Scrobble/Podcasts/Library. Do **not**
  put it in `Observability` (that module is the logging floor and should not grow a
  networking surface). Subsonic is out of scope -- it delegates HTTP to SwiftSonic.
- **Interface sketch:**
  ```swift
  public protocol HTTPClient: Sendable {
      func data(for request: URLRequest) async throws -> (Data, URLResponse)
  }
  extension URLSession: HTTPClient { /* delegate: nil */ }

  public struct HTTPStatus: Sendable { public let code: Int; public let retryAfter: TimeInterval? }
  public extension HTTPClient {
      /// Sends and returns the body + parsed status; callers map status -> their own typed error.
      func send(_ request: URLRequest) async throws -> (Data, HTTPStatus)
  }
  ```
- **Collapses:** the byte-identical `HTTPClient` protocol + `URLSession` conformance
  (Acoustics, Scrobble, Podcasts) into one; the `response as? HTTPURLResponse` +
  `statusCode` + `Retry-After` extraction repeated in each client into `send`.
- **Stays per-module:** typed error mapping (`AcousticsError`/`ScrobbleError`/`PodcastsError`),
  auth (PodcastIndex HMAC-SHA1, Last.fm `api_sig`, ListenBrainz `Token`), and payload
  building. The `RateLimiter` + `MusicBrainzClient` siblings (S3-9) sit above this layer;
  fold them once the shared client exists.

### Login-Keychain store (S5-4)
- **Home:** a small `LoginKeychain` helper (own leaf module, or alongside `Networking`).
- **Interface sketch:** `func read(service:account:) -> Data?`, `func upsert(_:service:account:)`,
  `func delete(service:account:)` -- generic-password items, file (login) Keychain, **no**
  `kSecAttrAccessible` and **no** `kSecUseDataProtectionKeychain` (per repo memory / TN3137).
- **Shares:** `Scrobble/Credentials` + `Subsonic/SubsonicServerStore` (both generic passwords).
- **Excluded:** `SyncServer/IdentityStore` stores a `SecKey` + certificate (a `SecIdentity`),
  a distinct concern -- leave it, or add a separate typed helper.

## Running totals

Update at the end of each session (Session 10 finalizes):

- Lines removed (net): _172_
- Consolidated: _4_  ·  Tolerated: _37_  ·  Rejected: _7_  ·  Deferred: _8_
- New shared helpers introduced: _3_ (`Database.fetchOne(_:id:entity:)`; `ListenBrainzCompatibleTransport`; `View.loadErrorAlert(_:message:)`) + Subsonic-internal `withClient`/`withCapabilityGatedClient`
- S6-5/S6-6 (deferred to S7) resolved: scroll-restore tolerated (S7-4, break-even); `CollectionModeToggle`/`ErrorState` not shadowed -- dead/superseded (S7-6).
- Session 10 queue (deferred, cross-module): `clamped(to:)` micro-helper (S2-4, ~46 sites); the HTTP client (concrete proposal above); the login-Keychain store (concrete proposal above); a shared duration/byte display formatter (S6-7, ~13 files).
