# Phase 21-12-h: Per-show settings (speed, sort, retention)

> Depends on: `phase21-12-podcast-features.md` (the contract), `phase21-9-ui-episodes.md`
> (the episode table), `phase21-10-nowplaying-polish.md` (the speed control and the global
> podcast-speed default). Read `_standards.md` and `phase21-0-overview.md` first.

## Goal

Per-show overrides that win over the app defaults, each nullable (nil = use the app default):

1. Default playback speed for that show's episodes (overrides global `podcast.playback.rate`).
2. Default episode sort: newest-first vs oldest-first.
3. Episode retention limit: keep newest N content rows (nil = keep all).
4. The existing auto-download flag, surfaced in the same place.

As a side effect, capture the feed's `itunes:type` (`episodic` / `serial`) into a new
`show_type` column and use it to pick the default sort (serial -> oldest-first) when the
user has not set an explicit `episode_sort`.

## Non-goals

- Per-episode overrides (these are show-level only).
- Retention by age or played-state (count only here; the transcript 30-day clock from
  sub-phase b is a separate concern, untouched).
- Deleting user state or downloaded files during retention (see Gotchas).
- Varispeed; speed reuses the existing pitch-preserving path. Changing the global-defaults
  UI (`PodcastSettingsView` stays as is).

## Outcome shape

```
Modules/Persistence/Sources/Persistence/Migrations/M025_PodcastPerShowSettings.swift   (new)
Modules/Persistence/Sources/Persistence/Migrations/Migrator.swift                       (register M025)
Modules/Persistence/Sources/Persistence/Records/Podcast.swift                           (4 fields + CodingKeys)
Modules/Persistence/Sources/Persistence/Repositories/PodcastRepository.swift            (setters, prune, preserve)
Modules/Persistence/Sources/Persistence/Repositories/EpisodeRepository.swift            (sort-direction param)
Modules/Persistence/Tests/PersistenceTests/MigrationTests.swift                         (24 -> 25 in two places)
Modules/Podcasts/Sources/Podcasts/Models/ParsedFeed.swift                               (showType field)
Modules/Podcasts/Sources/Podcasts/FeedParser.swift                                      (read channel.iTunes?.type)
Modules/Podcasts/Sources/Podcasts/Mapping/ParsedFeed+Records.swift                      (showType -> show_type)
Modules/Podcasts/Sources/Podcasts/PodcastService.swift                                  (prune after refresh)
Modules/UI/Sources/UI/Browse/Podcasts/PodcastShowSettingsView.swift                     (new sheet)
Modules/UI/Sources/UI/Browse/Podcasts/PodcastSeams.swift                                (extend PodcastActions)
Modules/UI/Sources/UI/Resources/Localizable.xcstrings                                   (new keys)
App/.../AppPodcastActions.swift                                                          (implement new setters)
```

## Data model

### Migration M025

`M024` is the highest registered (verify the bottom of `Migrator.swift`); next free integer
is **M025**. If an earlier 21-12 sub-phase took 025, use the next free integer and adjust
the file name and the two test assertions to match. `M025_PodcastPerShowSettings.swift`,
registered after `M024PodcastGUID.register` in `Migrator.make()`. Four nullable columns,
each a separate `table.add(column:)` in one `registerMigration("025_podcast_per_show_settings")`
block (mirror `M015_TrackExtendedTags.swift`):

```sql
ALTER TABLE podcasts ADD COLUMN playback_speed  REAL;     -- nil = use app default
ALTER TABLE podcasts ADD COLUMN episode_sort    TEXT;     -- 'newest' | 'oldest', nil = default
ALTER TABLE podcasts ADD COLUMN retention_limit INTEGER;  -- nil = keep all
ALTER TABLE podcasts ADD COLUMN show_type       TEXT;     -- 'episodic' | 'serial', from itunes:type
```

No backfill: `show_type` populates on the next refresh; overrides stay nil until set.

### `Podcast` record

Add four properties, four nil-defaulted init parameters (placed before the trailing
non-defaulted `addedAt`, so the existing `swiftlint:disable function_default_parameter_at_end`
span still covers them), and four `CodingKeys`:

```swift
public var playbackSpeed: Double?   // playback_speed   (user-owned)
public var episodeSort: String?     // episode_sort     (user-owned)
public var retentionLimit: Int?     // retention_limit  (user-owned)
public var showType: String?        // show_type        (feed-derived)
```

`playbackSpeed` / `episodeSort` / `retentionLimit` are user-owned (like `autoDownload` /
`sortIndex`); `showType` is feed-derived (like `title`). This split drives the upsert rule below.

### `MigrationTests` bump

`Modules/Persistence/Tests/PersistenceTests/MigrationTests.swift`: change both literals from
24 to 25: line 12 `#expect(version == 24)` and line 72 `#expect(migrator.migrations.count == 24)`.
The test name "twenty-four migrations" is cosmetic; update it for honesty if you like.

### Parse-side: capture `show_type`

- `ParsedFeed.showType: String?` added to `Models/ParsedFeed.swift` (stored property +
  nil-defaulted init param).
- `FeedParser.parseRSS` reads `channel.iTunes?.type`; normalize defensively (lowercase,
  trim, accept only `episodic` / `serial`, else nil). `parseAtom` has no equivalent, passes nil.
- `ParsedFeed.toPodcast` (`Mapping/ParsedFeed+Records.swift`) maps `self.showType` into the
  `showType:` initializer argument; it does not set the override columns (those are user
  state applied via repository setters).

## Implementation

**Playback speed.** Today `NowPlayingViewModel` reads `podcast.playback.rate` on the
music->podcast mode switch (around lines 589-611) and calls `setRate(_:)`, which flows
`QueuePlayer.setRate` -> `AudioEngine` -> `DSPChain.setRate` (pitch-preserving
`AVAudioUnitTimePitch`). When an episode of show X begins, the starting rate becomes
`podcast.playbackSpeed ?? UserDefaults podcast.playback.rate ?? 1.0`. The App's
`PodcastActions.play(episode:podcast:)` already holds the `Podcast`, so the App resolves the
rate and applies it when podcast playback begins (or stashes it for the mode switch to read).
A manual `SpeedPickerView` drag still calls `setRate` and overrides live; per-show speed only
sets the starting rate and never writes the global default.

**Episode sort.** `EpisodeRepository` hard-codes `ORDER BY e.published_at DESC` in the
private `joinedSQL` (line 207), used by `fetchListItems` and `observeListItems`. Add an
`EpisodeSortOrder` enum (`newest` / `oldest`) and build the SQL from a template interpolating
a fixed keyword (`.newest` -> `DESC`, `.oldest` -> `ASC`; never a user string, so no injection),
with a deterministic id tiebreaker for equal/NULL `published_at`. Add an `order:` parameter
(default `.newest`) to both fetch/observe. The App resolves order from the show: explicit
`episodeSort` wins, else derive from `show_type` (`serial` -> `.oldest`, else `.newest`).
`EpisodeList` (`Browse/Podcasts/EpisodeList.swift`) renders the order it receives; no view-side re-sort.

**Default-sort seeding (read-derived, not stored).** Do not write `'oldest'` into
`episode_sort` on subscribe. Keep it nil and derive the default from `show_type` at read
time, so a show that later changes `itunes:type` updates its default automatically.

**Retention.** Add `PodcastRepository.pruneEpisodes(podcastID:keepNewest:)`. Nil limit is a
no-op. Otherwise delete from `podcast_episodes` the rows not among the newest N by
`published_at DESC` (id tiebreaker), **except** any episode whose joined
`podcast_episode_state` shows `play_state` in (`inProgress`, `played`) OR `download_state =
'downloaded'`: those are exempt and kept even outside the newest N. The prune deletes only
cold content rows; it never deletes a `podcast_episode_state` row and never removes a
downloaded file on disk. Call it from `PodcastService.refresh` after the episode upsert (and
once on subscribe), best-effort: log at debug on failure, never fail the refresh.

**Repository setters + refresh preservation.** Add single-column `UPDATE ... WHERE id = ?`
setters mirroring `setSortIndex`: `setPlaybackSpeed`, `setEpisodeSort`, `setRetentionLimit`
(`setAutoDownload` already exists). **Extend the `upsertByFeedURL` preservation block**
(`PodcastRepository.swift` lines 58-63, which copies `id`, `addedAt`, `subscribed`,
`autoDownload`, `sortIndex` from the existing row) to also copy `playbackSpeed`,
`episodeSort`, `retentionLimit` so a refresh never clobbers a user override. Do **not** copy
`showType`: it is feed-derived and should refresh from the parse. Update the preserved-fields
doc comment (lines 47-49).

**Settings UI.** New `Browse/Podcasts/PodcastShowSettingsView.swift`: a sheet from the show
(toolbar gear and a context-menu "Show Settings..." on the episode header and grid tile).
Sections: playback speed (picker with an explicit "App Default" = nil plus the
`PodcastSettingsView` values `0.8, 1.0, 1.25, 1.5, 1.75, 2.0`); episode order (Newest /
Oldest / Use Default = nil, subtitle showing the resolved default); keep episodes (All = nil,
10, 25, 50, 100, with a note that in-progress / played / downloaded are kept); auto-download
toggle; a read-only detected show-type line. All chrome via `L10n`
(`Text(localized:)` / `L10n.string`) with new keys in `Resources/Localizable.xcstrings`; show
title/type is feed content, rendered verbatim. Run `make pseudolocale` after adding keys. Add
a source-convention test (the sheet cannot be unit-tested host-less).

**Seam additions (UI declares, App implements).** Extend `PodcastSeams.swift`; implement in
App over `PodcastService` / `PodcastRepository`. UI never imports `Podcasts`; only the App
sees `PodcastService` and `QueuePlayer` together.

```swift
// PodcastActions (add); setAutoDownload(_:podcastID:) already exists:
func setPlaybackSpeed(_ speed: Double?, podcastID: Int64) async throws
func setEpisodeSort(_ sort: String?, podcastID: Int64) async throws   // "newest" | "oldest" | nil
func setRetentionLimit(_ limit: Int?, podcastID: Int64) async throws
```

The episode-list view model resolves the effective sort from the `Podcast` it already has and
passes the order to the data source. To keep `observeEpisodes` stable, add an `order:`
overload rather than breaking existing call sites; the App maps it to `EpisodeRepository`.

## Context7 lookups

None. No new third-party API: GRDB column adds, the already-used FeedKit `channel.iTunes?.type`,
and the existing `AVAudioUnitTimePitch` path. (Standing rule: if you do reach for a library
detail, use the latest version and avoid deprecated APIs.)

## Test plan

Swift Testing, per-module coverage floors, no network (stub feeds via `HTTPClient` mock /
`URLProtocol`; fixtures under each module's `Tests/.../Fixtures/`).

- Persistence: migration applies cleanly at version 25 / count 25 and the four columns exist
  (`PRAGMA table_info`); `Podcast` round-trips with the fields set and nil; each setter
  updates only its column; `upsertByFeedURL` preserves the three overrides and refreshes
  `show_type`; `fetchListItems(order: .oldest)` is ascending with a deterministic tiebreaker;
  retention keeps exactly the newest N plus an `inProgress` and a `downloaded` exemption,
  deletes the rest, and leaves all state rows intact (nil limit is a no-op).
- Podcasts: `FeedParser` reads `itunes:type` into `showType` (fixtures: serial, episodic,
  missing -> nil, garbage -> nil; Atom -> nil); `toPodcast` maps it and leaves overrides nil;
  subscribing a serial feed leaves `episode_sort` nil (default is derived).
- UI: source-convention test that the sheet exposes the four controls and localized copy and
  that "App Default" / "Use Default" map to nil; `L10nTests` / en-XA covers the new keys.
- App: setters route to the repository; a unit test over the rate resolver asserts
  `playbackSpeed ?? global ?? 1.0` (no audio).

## Acceptance criteria

- [ ] `M025_PodcastPerShowSettings.swift` adds the four nullable columns and is registered.
- [ ] `MigrationTests` version and count read 25 and pass.
- [ ] `Podcast` has the four fields / params / CodingKeys and round-trips.
- [ ] `FeedParser` populates `ParsedFeed.showType` (normalized) and `toPodcast` maps `show_type`.
- [ ] Episode table honors `episode_sort`; when nil, serial -> oldest-first, else newest-first.
- [ ] Per-show speed sets the starting rate (falling back to global) without changing the global.
- [ ] Retention keeps exactly the newest N plus in-progress / played / downloaded exemptions,
  deletes the rest, never deletes a state row or a downloaded file.
- [ ] `upsertByFeedURL` preserves the three overrides; `show_type` refreshes from the feed.
- [ ] A localized per-show sheet exposes speed, sort, retention, auto-download; `make pseudolocale` is clean.
- [ ] `PodcastActions` gains the three setters, implemented in App; no upward imports.
- [ ] `make format && make lint && make build && make test-persistence && make test-podcasts && make test-ui` pass.

## Gotchas

- **Retention must never clobber user state or downloads.** Count-based over cold content rows
  only; in-progress / played / downloaded episodes are exempt even outside the newest N;
  `podcast_episode_state` rows and on-disk files are never touched. A re-appearing GUID
  re-binds to its preserved state on the next upsert.
- **Default vs override in one place.** Sort and speed both resolve as "explicit per-show
  value, else app default" (sort derives its default from `show_type`). Keep `episode_sort`
  nil until the user picks; do not seed `'oldest'` on subscribe.
- **Speed scope is per show, not global, not per episode.** It sets the starting rate when the
  show begins; a manual `SpeedPickerView` change overrides live and is not written back.
  Switching to music restores the music rate as today.
- **`show_type` is feed-derived.** Add only the three overrides to the `upsertByFeedURL`
  preservation copy; leaving `show_type` out is deliberate.
- **No injection via the sort keyword.** Interpolate a fixed `ASC` / `DESC` from the enum,
  never a user string; keep an id tiebreaker.
- **Migrations are immutable once shipped.** If 025 is taken, use the next free integer and
  keep the two test assertions in lockstep.

## Handoff

Each show carries optional speed / sort / retention overrides plus a feed-derived `show_type`;
the episode table and player honor them with clean default-vs-override resolution; refresh
preserves user overrides while refreshing `show_type`; a localized per-show sheet drives the
new `PodcastActions` setters from the App. Retention is count-based and state-safe, leaving
room for a future age-based or played-based policy without disturbing the transcript cleanup
(sub-phase b) or unread counts (sub-phase f).
