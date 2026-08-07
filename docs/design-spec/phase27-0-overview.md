# Phase 27: Internet Radio

> Prerequisites: Phases 0-26 complete. The play path already exists end to
> end: `PlayableSource.internetRadio(streamURL:)` (Playback) is the one
> live-stream case (`isLiveStream`, scrubber disabled via `duration == 0`,
> no history or scrobble writes), `DecoderFactory` routes any http(s) URL to
> `FFmpegDecoder` (ICY/Shoutcast handled), and `AudioEngine+Reconnect` is
> the backstop for dropped streams. Phase 19's per-server "Internet Radio"
> rows and `SubsonicInternetRadioView` stay as they are; this phase adds the
> local, user-curated station catalog beside them. Closes #376.
>
> Read `docs/design-spec/_standards.md` first.

## The brief

Radio as a first-class destination. A "Radio" row in the sidebar's Local
Library section (directly under Podcasts, which is the placement precedent:
user-curated streamed content, not server-bound), backed by a persisted
station catalog with add/edit UI. Playlist import learns that a stream URL
is a station, not a missing file: issue #376's 26-entry M3U currently
resolves to 26 misses and an empty playlist.

## Slices

### 27-1: Station catalog (Persistence)

- Migration `M036_RadioStations`, id `036_radio_stations`, registered after
  035 in `Migrator`: table `radio_stations` with `id` (pk), `name` (NOT
  NULL), `stream_url` (NOT NULL, UNIQUE), `home_page_url` (nullable),
  `added_at` (epoch seconds, NOT NULL).
- `RadioStation` record plus `RadioStationRepository`: `fetchAll()` ordered
  by name, `insert`, `update`, `delete`, an upsert keyed on `stream_url`
  (what makes re-import idempotent), and `observeAll()` as an
  `AsyncThrowingStream` following the `TrustedDeviceRepository` pattern.

### 27-2: Play path (UI)

- Extract `QueueItem.makeInternetRadio` out of
  `LibraryViewModel+Subsonic.swift` into a shared factory taking name,
  stream URL, and homepage. Keep its conventions exactly: `trackID: -1`,
  `duration: 0` (that zero is what disables the scrubber in the transport
  strips), artist "Internet Radio", album carries the homepage. The
  Subsonic call site delegates to it.
- `LibraryViewModel.play(radioStation:)`: replace the queue with the single
  item, shuffle off, mirroring the existing Subsonic radio play path.
- No Playback module changes. The case already carries everything needed;
  display metadata rides on `QueueItem`. Do not widen the `PlayableSource`
  Codable enum: that would drag in a `QueuePersistence` migration for no
  benefit.

### 27-3: Radio destination (UI)

- New `SidebarDestination.radio` case. Adding a case is decode-compatible
  with saved `ui.state.v2` blobs (phase 21 added `.podcasts` the same way,
  no key bump); refresh the stale `UIStateV1` doc comment on the enum while
  there.
- Sidebar row in the Local Library section under Podcasts: symbol
  `dot.radiowaves.left.and.right` (matches the per-server radio rows;
  Podcasts keeps the antenna), localized label "Radio". Plus the
  `ContentPane` switch arm, membership in `loadDestination`'s self-loading
  no-op arm, and the window-title mapping beside the others.
- `RadioView` and view model modeled on `SubsonicInternetRadioView` (list,
  hover play, double-click to play, info sheet, VoiceOver rotor actions)
  plus what the read-only original never needed: an add/edit station sheet
  (name, stream URL, optional homepage; scheme must be http or https; no
  reachability check, tests must not hit the network), delete behind a
  confirmation, and a `ContentUnavailableView` empty state with an Add
  Station button. The list observes `observeAll()` so external changes
  (import, 27-4) appear live. Alphabetical order, no manual sorting.
- Localization keys with plural variations where counts appear, then
  `make pseudolocale`; a11y identifiers; snapshot plus source-convention
  tests mirroring `PodcastsSidebarConventionTests`.

### 27-4: Import hook (Library + UI), closes #376

- `M3UReader.resolveURL` deliberately returns nil for non-file schemes, so
  a stream URL survives only in `Entry.path` and the resolver logs it as a
  miss. Partition entries by URL scheme in
  `PlaylistImportService.importPayload` before resolution: http(s) entries
  never reach `TrackResolver`. Partitioning at the payload level covers
  M3U, M3U8, PLS, and XSPF in one place (CUE takes its own path and is
  unaffected).
- Stream entries upsert into `radio_stations`, station name from the
  entry's title hint (`#EXTINF` in M3U, `TitleN` in PLS, `<title>` in
  XSPF), falling back to the URL host. `ImportReport` gains a stations
  count. A playlist row is created only when the payload holds at least one
  non-stream entry, so an all-stream file yields stations and no empty
  playlist.
- `PlaylistImportSheet`'s preview grows a stations line; the drag-drop path
  (`LibraryViewModel+PlaylistDrop`) shares `importPayload` and inherits the
  behaviour; the completion toast owns the split (stations added, tracks
  matched, entries missed).
- README and website feature blurb.

## Non-goals

- No ICY StreamTitle "now playing" metadata; the station name is the title.
  FFmpeg exposes the ICY headers, so a later polish phase can layer this on
  without schema changes.
- No artwork or station logos.
- No play history or scrobbling for stations: `QueuePlayer` already returns
  early for `.internetRadio` by design; unchanged.
- No push to Subsonic servers (SwiftSonic's create/update/delete radio
  endpoints stay unused) and no merging of server stations into the local
  catalog.
- Streams never become playlist entries; playlists stay library-track-only.
- No global-search integration for stations.

## Risks

- A mixed file (local tracks plus streams) imports as a playlist and
  separate stations; a user might expect one ordered list. The preview
  sheet and the toast state the split plainly before and after anything is
  written.
- The add-station sheet validates shape, not reachability, so a dead or
  geo-blocked URL fails only at play time. That surfaces through the
  existing engine error path and reconnect backstop, which is exactly how
  Subsonic radio behaves today.
- Station names from `#EXTINF` are frequently junk ("0," prefixes, empty
  titles). The host-name fallback plus the edit sheet is the answer;
  import must never write an empty name.
