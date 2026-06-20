# Phase 21-12-b: Transcripts (fetch, store, view, self-clean)

> Depends on: `phase21-12-podcast-features.md` (the contract; read its "Shared
> semantics" transcript-cleanup section) and `phase21-11-feedkit-upgrade.md`
> (FeedKit 10.4.0 already populates `podcast_episodes.transcript_url`). Read
> `_standards.md` and `phase21-0-overview.md` first.

## Goal

Make an episode's transcript fetchable, viewable (including offline), and
self-cleaning. `transcript_url` already exists per episode. This slice:

1. Adds a re-fetchable cache table (`podcast_episode_transcript`) that stores the
   transcript content in full, so the viewer works offline.
2. Adds a `TranscriptFetcher` + parser in the `Podcasts` module that fetches via
   the existing `HTTPClient` seam and parses WebVTT, SRT, the Podcasting 2.0 JSON
   transcript format, HTML, and plain text into a normalized `[TranscriptCue]`
   (timed) or plain text (untimed).
3. Adds a 30-day cleanup sweep that deletes transcript rows whose episode is
   `played` and whose clock (`completed_at` else `last_played_at`) is older than
   30 days, wired into the same launch and post-refresh hooks
   `FeedRefreshScheduler` uses.
4. Adds a Transcript viewer (sheet) opened from the episode context menu and from
   Now Playing, behind a new `PodcastSeams.swift` protocol implemented in App.

## Non-goals

- Editing, translating, or searching transcript text (verbatim render only).
- Generating transcripts (no speech-to-text); we only fetch what the feed links.
- Multi-transcript pickers (language/format choice). `transcript_url` is one URL
  per episode (FeedKit picks the best one in 21-11); we cache and show that one.
- Current-cue highlight and tap-to-seek are a documented stretch, not required.

## Outcome shape (file tree)

```
Modules/Persistence/Sources/Persistence/
  Migrations/M025_PodcastTranscript.swift          (new)
  Migrations/Migrator.swift                         (register M025)
  Records/PodcastTranscript.swift                   (new record + TranscriptFormat enum)
  Repositories/TranscriptRepository.swift           (new: upsert/fetch/cleanup)
Modules/Persistence/Tests/PersistenceTests/
  TranscriptRepositoryTests.swift                   (new)
  MigrationTests.swift                              (bump two assertions)

Modules/Podcasts/Sources/Podcasts/
  Transcripts/TranscriptFetcher.swift               (new: fetch -> store)
  Transcripts/TranscriptParser.swift                (new: bytes+format -> cues/text)
  Transcripts/TranscriptCue.swift                   (new: TranscriptCue, TranscriptContent)
  Transcripts/TranscriptCleanup.swift               (new: 30-day sweep)
  PodcastService.swift                              (add transcript(...) + sweepTranscripts())
  FeedRefreshScheduler.swift                        (call the sweep on launch + post-fan-out)
Modules/Podcasts/Tests/PodcastsTests/
  TranscriptParserTests.swift                       (new)
  TranscriptCleanupTests.swift                      (new)
  Fixtures/transcript-sample.vtt|.srt|.json         (new, hand-authored)

Modules/UI/Sources/UI/Browse/Podcasts/
  PodcastSeams.swift                                (add PodcastTranscriptProviding)
  TranscriptView.swift                              (new: the sheet/viewer)
  EpisodeList.swift                                 (add "Transcript" context-menu item)
Modules/UI/Sources/UI/Transport/
  PodcastTransportControls.swift                    (add a transcript affordance)
Modules/UI/Sources/UI/Resources/Localizable.xcstrings  (new keys)

App/
  AppPodcastTranscript.swift                        (new: PodcastTranscriptProviding adapter)
  BocanApp.swift                                    (inject adapter; sweep already via scheduler)
```

## Data model (new table + migration)

`transcript_url` lives on `podcast_episodes`; the fetched content is precious to
keep offline but cheap to re-fetch, so it goes in its own cacheable table keyed by
the same stable `(podcast_id, guid)` identity the rest of the podcast state uses.

### `podcast_episode_transcript` (re-fetchable cache; cleanable)

```sql
CREATE TABLE podcast_episode_transcript (
    podcast_id  INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
    guid        TEXT NOT NULL,
    content     TEXT NOT NULL,        -- the raw fetched body, verbatim
    format      TEXT NOT NULL,        -- 'vtt' | 'srt' | 'json' | 'html' | 'plain'
    language    TEXT,                 -- BCP-47 when the feed/HTTP gives one
    source_url  TEXT NOT NULL,        -- the transcript_url it was fetched from
    fetched_at  REAL NOT NULL,        -- epoch seconds
    PRIMARY KEY (podcast_id, guid)
);
```

`M025_PodcastTranscript.swift` (next free integer; M024 is the highest registered,
confirm at the top of `Migrator.swift`) creates the table and registers in
`Migrator.make()` after `M024PodcastGUID.register(...)`. No backfill, no index
beyond the PK (lookups and the cleanup join are both by `(podcast_id, guid)` or a
full scan over a small table). `ON DELETE CASCADE` mirrors the other podcast
tables so unsubscribing drops the cache.

Record: `PodcastTranscript` (`Codable, Equatable, Hashable, FetchableRecord,
PersistableRecord, Sendable`, `databaseTableName = "podcast_episode_transcript"`,
CodingKeys mapping snake_case), alongside a `TranscriptFormat: String, Codable,
Sendable, CaseIterable` enum (`vtt, srt, json, html, plain`). Mirror the style of
`PodcastEpisodeState.swift` (composite PK, `PersistableRecord` not mutable).

### Store raw + format, parse at view time (the choice)

Store the raw `content` plus a `format` discriminator and parse to cues lazily when
the viewer opens. Rationale: the raw body is the lossless source of truth (a later
parser fix re-parses old caches with no migration); a transcript is read rarely, so
the parse cost is cheap when paid on demand; and the fetch path stays
format-agnostic, leaving the parser a pure, I/O-free, fully-unit-testable function.
Alternative rejected for now: parse on fetch and store normalized JSON cues. That
makes the viewer trivial but bakes the parser version into stored data (a fix needs
a re-fetch or migration) and discards original formatting. Note this trade-off in
the record's doc comment so a future change is deliberate.

## Implementation

### Normalized cue type (Podcasts module)

```swift
public struct TranscriptCue: Sendable, Hashable, Identifiable {
    public var id: Int                 // index in the parsed sequence
    public var start: TimeInterval     // seconds
    public var end: TimeInterval?      // nil when the format gives no end
    public var speaker: String?        // from JSON `speaker` or VTT voice tags
    public var text: String
}

public enum TranscriptContent: Sendable, Hashable {
    case timed([TranscriptCue])
    case plain(String)
}
```

### TranscriptParser (pure, no I/O)

`func parse(_ content: String, format: TranscriptFormat) -> TranscriptContent`.
One private parser per format; all are best-effort and never throw (a malformed
body degrades to `.plain(content)` rather than failing the viewer):

- **WebVTT (`vtt`)**: skip the `WEBVTT` header and `NOTE`/`STYLE` blocks; split on
  blank lines; parse `HH:MM:SS.mmm --> HH:MM:SS.mmm` cue timing (also `MM:SS.mmm`);
  strip cue settings after the timestamp; lift `<v Speaker>` voice tags into
  `speaker`; strip remaining inline tags from the text.
- **SRT (`srt`)**: numbered blocks, `HH:MM:SS,mmm --> HH:MM:SS,mmm` (comma
  decimal separator, the key VTT-vs-SRT difference); join multi-line text.
- **JSON (`json`)**: the Podcasting 2.0 transcript JSON shape, a top-level object
  with a `segments` (a.k.a. `version`/`segments`) array of `{ startTime, endTime,
  speaker?, body }` objects (verify exact key names at implementation, see
  Context7). Map to timed cues; when timing is absent, fall back to `.plain`.
- **HTML (`html`)**: strip tags to text (reuse the `<script>`-stripping approach
  from `ShowNotesView.HTMLLoader`; here we want plain text, so we can render via
  the same NSAttributedString path or a tag-stripped string) and return `.plain`.
- **Plain (`plain`)**: return `.plain(content)` unchanged.

A `TranscriptFormat.infer(fromURL:mime:)` helper maps the `transcript_url`
extension and/or the HTTP `Content-Type` to a format, defaulting to `.plain`.

### TranscriptFetcher (Podcasts module)

```swift
public actor TranscriptFetcher {
    public init(http: any HTTPClient = URLSession.shared, maxBytes: Int = 5 * 1024 * 1024)
    /// Fetch the transcript body for an episode and persist it. Returns the row.
    public func fetchAndStore(
        podcastID: Int64, guid: String, transcriptURL: URL, language: String?
    ) async throws -> PodcastTranscript
}
```

Mirror `FeedFetcher`: set `User-Agent`, respect `Task.checkCancellation()`, cap
the body size (`PodcastsError.feedTooLarge`), only accept `http`/`https` URLs
(`PodcastsError.invalidFeedURL` otherwise, treating feed URLs as untrusted),
decode bytes as UTF-8 (fall back to lossy decoding rather than failing), infer the
format from URL+`Content-Type`, then upsert via `TranscriptRepository`. All logs
go through `AppLogger.make(.podcasts)` with `transcript.fetch.start/end/failed`.

### PodcastService entry point + seam

Add to `PodcastService`:

```swift
/// Returns the cached transcript if present, else fetches it from the episode's
/// transcript_url, stores it, and returns it. Throws PodcastsError when the
/// episode has no transcript_url or the fetch fails.
public func transcript(podcastID: Int64, guid: String) async throws -> PodcastTranscript
```

It reads the cache first (`TranscriptRepository.fetch`), and on a miss looks up the
episode's `transcript_url` (via `EpisodeRepository`), then delegates to
`TranscriptFetcher`. `nil` `transcript_url` -> `PodcastsError.notFound`. This is
the method the App-side seam calls.

### TranscriptRepository (Persistence module)

The sole writer of `podcast_episode_transcript`. Methods:

- `fetch(podcastID:guid:) async throws -> PodcastTranscript?`
- `upsert(_ transcript: PodcastTranscript) async throws` (INSERT ... ON CONFLICT
  on the composite PK, replacing `content/format/language/source_url/fetched_at`).
- `deletePlayedOlderThan(cutoff: Double) async throws -> Int` (the cleanup;
  returns the number of rows deleted, for the log line).

The cleanup is a single DELETE joined to `podcast_episode_state`:

```sql
DELETE FROM podcast_episode_transcript
WHERE (podcast_id, guid) IN (
    SELECT t.podcast_id, t.guid
    FROM podcast_episode_transcript t
    JOIN podcast_episode_state s
      ON s.podcast_id = t.podcast_id AND s.guid = t.guid
    WHERE s.play_state = 'played'
      AND COALESCE(s.completed_at, s.last_played_at) IS NOT NULL
      AND COALESCE(s.completed_at, s.last_played_at) <= :cutoff
);
```

`cutoff = now - 30 * 24 * 60 * 60`. A transcript with no state row, or a state row
that is `unplayed`/`inProgress`, or one with no clock timestamp, is never deleted.
Pass `now` in (do not call `Date()` inside the repo) so tests are deterministic.

### Cleanup sweep wiring (the clock)

Add `func sweepTranscripts() async` to `PodcastService` that computes the cutoff
from `self.now()` and calls `TranscriptRepository.deletePlayedOlderThan`, logging
`transcript.cleanup` with the deleted count. Wire it into `FeedRefreshScheduler`
at the two hooks the contract names:

- **Launch**: the App already runs `Task.detached { await feedRefreshScheduler.start() }`
  in `BocanApp.buildGraph` (around line 674). Have `start()` call
  `service.sweepTranscripts()` once before entering the refresh loop.
- **Post-refresh fan-out**: inside the loop, after each `await svc.refreshAllStale()`
  (and in `refreshNow()`), call `await svc.sweepTranscripts()`.

This reuses the existing scheduler ownership and the App's launch hook unchanged;
no new App-side scheduling. Cross-reference: sub-phase f's "Mark all as played"
sets `play_state = 'played'` with `completed_at = now` on every episode, which
starts this 30-day clock for each. That interaction is intentional; the cleanup is
indifferent to whether the clock was started by playback completion or a bulk
mark-played.

### Viewer + seam (UI module, behind PodcastSeams)

Add a protocol in `PodcastSeams.swift` (UI never imports `Podcasts`; the seam type
`PodcastTranscript` comes from `Persistence`, which UI already imports):

```swift
public protocol PodcastTranscriptProviding: Sendable {
    /// Cached-or-fetched transcript for an episode. Throws when none exists or
    /// the fetch fails; the viewer maps that to its empty/disabled state.
    func transcript(podcastID: Int64, guid: String) async throws -> PodcastTranscript
}
```

`PodcastsViewModel` gains an injected `transcriptProvider: PodcastTranscriptProviding?`
(mirroring `actions`/`search`) and `async func loadTranscript(for:) ->
TranscriptContent?` that calls the provider, then parses. The parser lives in
`Podcasts`, which UI cannot import, so the UI parses with its own pure parser over
`(content, format-string)` (the record's `format` is a plain `String`). This keeps
the viewer free of any App round-trip and trivially snapshot-testable; the Podcasts
and UI parsers share fixtures but not code, respecting no-upward-imports.

`TranscriptView.swift` (a `.sheet`, modelled on `ShowNotesView`): header
`Text(localized: "Transcript")`, a `Divider`, then `.timed(cues)` as a `ScrollView`
of rows (optional speaker, optional monospaced timestamp, cue text, all
`Text(verbatim:)` + `textSelection(.enabled)`); `.plain(text)` as one selectable
scrollable `Text(verbatim:)`; loading as `ProgressView`; and empty/error/no-transcript
as `ContentUnavailableView(L10n.string("No transcript available for this episode."),
systemImage: "captions.bubble")`. Open it from two places:

- **EpisodeList context menu**: add a `Button(L10n.string("Transcript"))` next to
  "Show Notes", gated on `item.episode.transcriptURL != nil` (disabled/hidden
  otherwise), setting selection and presenting the sheet, exactly like the existing
  `showingNotes` flow.
- **Now Playing**: in `PodcastTransportControls`, add a transcript button (e.g.
  `Image(systemName: "captions.bubble")`) shown only when
  `vm.isPodcast && vm.podcastID != nil && vm.podcastGUID != nil`; it presents the
  same sheet using `vm.podcastID` / `vm.podcastGUID`. Disable when those are nil.

App wiring: `AppPodcastTranscript.swift` conforms an adapter to
`PodcastTranscriptProviding` over `PodcastService.transcript(...)` (the empty
`@retroactive` conformance pattern used for `PodcastLibraryDataSource` works if the
signatures match exactly; otherwise a thin struct adapter like
`AppPodcastActions`). Inject it into `LibraryViewModel` -> `PodcastsViewModel`
alongside the existing podcast seams in `buildGraph`.

Stretch (documented, not required): current-cue highlight tracks
`NowPlayingViewModel` progress against `cue.start/end`; tap-to-seek on a cue calls
into the player. Seeking a podcast episode goes through `QueuePlayer` (the
`vm.seek`/transport path), never the `AudioEngine` directly, per the overview.

## Context7 lookups (verify at implementation)

- **WebVTT** (W3C) and **SRT (SubRip)**: confirm the timestamp grammars,
  especially VTT `.` vs SRT `,` decimal separators, optional hours, cue settings
  after the `-->`, and VTT `<v ...>` voice spans and `NOTE`/`STYLE` blocks.
- **Podcasting 2.0 JSON transcript** (`podcastnamespace` / `transcripts` tag spec):
  confirm the JSON object shape and exact key names (`version`, `segments`,
  `startTime`, `endTime`, `speaker`, `body`) before finalizing the JSON decoder.
- **FeedKit 10.4.0**: re-confirm that `transcript_url` is the single best-effort
  URL 21-11 wrote (no change needed here, but the column contract matters).

## Test plan

Swift Testing, no network (inject the `HTTPClient` mock / `URLProtocol` stub),
fixtures hand-authored and checked in under `Modules/Podcasts/Tests/PodcastsTests/
Fixtures/`. 80% line coverage per touched module.

- **Parse correctness** (`TranscriptParserTests`): hand-authored `transcript-sample.vtt`,
  `.srt`, and `.json` fixtures. Assert cue count, first/last `start`/`end` seconds,
  a speaker lifted correctly, comma-vs-dot timing parsed for each, and that a
  malformed body degrades to `.plain` rather than crashing. A plain-text input
  round-trips unchanged.
- **Store / fetch round-trip** (`TranscriptParserTests` + `TranscriptRepositoryTests`
  with an `HTTPClient` mock): `TranscriptFetcher.fetchAndStore` writes a row whose
  `content`/`format`/`source_url` match the served body; a second `transcript(...)`
  call hits the cache and does not re-fetch (assert the mock saw exactly one
  request).
- **Cleanup** (`TranscriptCleanupTests` / `TranscriptRepositoryTests`): seed
  transcripts for four episodes: (a) `played`, clock 31 days old; (b) `played`,
  clock 29 days old; (c) `inProgress`; (d) `unplayed` (or no state row). Run the
  sweep at a fixed `now`; assert only (a) is deleted and (b)(c)(d) remain.
- **Migration** (`MigrationTests`): bump `schemaVersion` to 25 and the
  `migrations.count` to 25; add a test asserting `podcast_episode_transcript`
  exists and add it to the expected-tables list.
- **Viewer chrome** (UI source-convention test): the `TranscriptView` and the two
  entry points route every label through `L10n` (no bare literals) and present the
  empty-state `ContentUnavailableView`. Add an `L10nTests` entry for the new keys.
  Run `make pseudolocale` after adding catalog keys (en-XA coverage gates CI).

## Acceptance criteria

- [ ] `podcast_episode_transcript` exists via `M025_PodcastTranscript`, registered
      in `Migrator.make()`; `MigrationTests` schemaVersion (25) and count (25)
      bumped, plus a table-exists assertion.
- [ ] `TranscriptParser` parses VTT, SRT, Podcasting 2.0 JSON, HTML, and plain
      text into `TranscriptContent`, degrading malformed input to `.plain`.
- [ ] `TranscriptFetcher` fetches via the `HTTPClient` seam (User-Agent, size cap,
      cancellation, http/https only, UTF-8 with lossy fallback) and stores raw
      content + format; `PodcastService.transcript(...)` is cache-first.
- [ ] `TranscriptRepository.deletePlayedOlderThan` deletes only `played` rows whose
      `COALESCE(completed_at, last_played_at)` is older than 30 days; `inProgress`,
      `unplayed`, and no-state-row transcripts are kept.
- [ ] The sweep runs at launch and after the refresh fan-out via the existing
      `FeedRefreshScheduler` hooks; no new App-side scheduler.
- [ ] A Transcript sheet opens from the episode context menu (gated on
      `transcript_url`) and from Now Playing (gated on `isPodcast` + ids), renders
      timed cues or plain text, and shows a localized empty/disabled state.
- [ ] `PodcastTranscriptProviding` declared in `PodcastSeams.swift` and implemented
      in App; UI does not import `Podcasts`.
- [ ] All new chrome localized; `make pseudolocale` run; `L10nTests` cover the new
      keys.
- [ ] `make format && make lint && make build && make test-persistence &&
      make test-podcasts && make test-ui` green; coverage at or above floor.

## Gotchas

- **Large transcripts.** Some transcripts are big (a long episode can be hundreds
  of KB of text). Cap the fetch body (`maxBytes`), and let the viewer lazily render
  rows (the `ScrollView`/`Table` is fine for a few thousand cues; do not pre-build
  one giant `AttributedString` for timed formats). Parsing stays off the main actor
  where it crosses into the UI.
- **Encoding.** Transcript servers are sloppy about charset. Decode UTF-8 first,
  then fall back to a lossy decode rather than throwing; store what we decoded so
  the viewer always has something. Strip a UTF-8 BOM before parsing VTT (a leading
  BOM breaks the `WEBVTT` header match).
- **SRT vs VTT.** The decimal separator differs (`,` vs `.`) and SRT has leading
  cue index lines; do not share one regex blindly. Infer format from URL+MIME but
  let the parser be tolerant if the inference is wrong.
- **Cleanup interaction with mark-all (sub-phase f).** "Mark all as played" stamps
  `completed_at = now` on every episode, so it starts the 30-day clock for every
  transcript of that show at once. That is intended: a show the user bulk-clears
  will shed its cached transcripts 30 days later. Call this out in the f spec too.
- **Re-fetch after cleanup.** A deleted transcript is not gone forever: opening the
  viewer re-fetches from `transcript_url` if the feed still serves it. The empty
  state must read as "not available", not "permanently deleted".
- **No upward imports.** Fetch + cache + cleanup live in `Podcasts`/`Persistence`;
  the viewer and its parser live in `UI` behind `PodcastSeams`; `App` wires the
  adapter. Do not let `UI` reach into `Podcasts` for the parser.

## Handoff

- Episodes have a viewable, offline-capable transcript that re-fetches on demand
  and cleans itself 30 days after the episode is played.
- The cleanup clock is shared with sub-phase f: bulk mark-played starts it; both
  specs document the interaction.
- `podcast_episode_transcript` is the home for any future transcript work (search,
  language picker, normalized-cue caching) without re-touching the fetch path.
