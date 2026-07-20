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

<!--
Append rows below per session. Keep the example row at the top as the format
reference. Do not delete rows once written.
-->

## Running totals

Update at the end of each session (Session 10 finalizes):

- Lines removed (net): _17_
- Consolidated: _1_  ·  Tolerated: _10_  ·  Rejected: _4_  ·  Deferred: _2_
- New shared helpers introduced: _1_ (`Database.fetchOne(_:id:entity:)`)
- Session 10 queue (deferred, cross-module): `clamped(to:)` micro-helper (S2-4, ~46 sites); HTTP request/decode/error-map client shape (S2-5, recurs in Acoustics/Scrobble/Subsonic).
