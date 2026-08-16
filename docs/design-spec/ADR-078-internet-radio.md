# ADR-078: Internet Radio

> Prerequisites: ADR-001 to ADR-077 complete. The play path already exists end to
> end: `PlayableSource.internetRadio(streamURL:)` (Playback) is the one
> live-stream case (`isLiveStream`, scrubber disabled via `duration == 0`,
> no history or scrobble writes), `DecoderFactory` routes any http(s) URL to
> `FFmpegDecoder` (ICY/Shoutcast handled), and `AudioEngine+Reconnect` is
> the backstop for dropped streams. `FFmpegDecoder+Options.swift` already
> sends the real `UserAgent.string` and bounded `reconnect*` options on
> every remote open, and FFmpeg's http protocol requests ICY metadata by
> default (`icy=1`) and de-interleaves it in-protocol, so now-playing
> titles are an engine seam away, not a proxy away. ADR-035's per-server
> "Internet Radio" rows and `SubsonicInternetRadioView` stay as they are;
> this ADR adds the local, user-curated station catalog beside them.
> Closes #376.
>
> Read `docs/design-spec/_standards.md` first.

## The brief

Radio as a first-class destination. A "Radio" row in the sidebar's Local
Library section (directly under Podcasts, which is the placement precedent:
user-curated streamed content, not server-bound), backed by a persisted
station catalog with add/edit UI, live now-playing titles from ICY
metadata, and playlist import that learns a stream URL is a station, not a
missing file: issue #376's 26-entry M3U currently resolves to 26 misses
and an empty playlist.

## Slices

### ADR-078 slice 1: Station catalog (Persistence)

- Migration `M036_RadioStations`, id `036_radio_stations`, registered after
  035 in `Migrator`: table `radio_stations` with `id` (pk), `name` (NOT
  NULL), `stream_url` (NOT NULL, UNIQUE), `home_page_url` (nullable),
  `added_at` (epoch seconds, NOT NULL), plus nullable station-profile
  columns filled in by ADR-078 slice 5 on successful connect: `genre`,
  `station_description`, `last_codec`, `last_bitrate_kbps`,
  `last_connected_at`. The profile makes the info sheet useful offline and
  gives later ADRs (loudness, honesty) a home without another migration.
- `RadioStation` record plus `RadioStationRepository`: `fetchAll()` ordered
  by name, `insert`, `update`, `delete`, an upsert keyed on `stream_url`
  (what makes re-import idempotent), a profile-update method that only
  fills fields the user has not edited, and `observeAll()` as an
  `AsyncThrowingStream` following the `TrustedDeviceRepository` pattern.

### ADR-078 slice 2: Play path (UI)

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

### ADR-078 slice 3: Radio destination (UI)

- New `SidebarDestination.radio` case. Adding a case is decode-compatible
  with saved `ui.state.v2` blobs (ADR-037 added `.podcasts` the same way,
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
  reachability check), delete behind a confirmation, and a
  `ContentUnavailableView` empty state with an Add Station button. The
  info sheet shows the ADR-078 slice 1 profile fields when present. The list observes
  `observeAll()` so external changes (import, profile capture) appear
  live. Alphabetical order, no manual sorting.
- Playlist-URL indirection in the add sheet: a pasted URL that is itself a
  playlist (`.pls` / `.m3u`, or a body that sniffs as one) gets fetched
  via URLSession and parsed with the existing `PLSReader` / `M3UReader`,
  and its stream entries are offered as stations. A body carrying
  `EXT-X-` tags is an HLS playlist, not a station list: keep the pasted
  URL as the stream URL. Tests stub the fetch via `URLProtocol`; no test
  touches the network.
- Localization keys with plural variations where counts appear, then
  `make pseudolocale`; a11y identifiers; snapshot plus source-convention
  tests mirroring `PodcastsSidebarConventionTests`.

### ADR-078 slice 4: Import hook (Library + UI), closes #376

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

### ADR-078 slice 5: ICY now-playing, stream details, and station profile (AudioEngine + Playback + UI)

Scope grew on request: the player's info button, disabled for radio today
(it keys on a `tracks` row id that radio items never have), opens the
station info sheet instead, enriched with everything the open decoder
knows. A `StreamDetails` snapshot (container, codec and profile, sample
rate, channels, claimed bitrate, the `icy-*` headers, and whether the
station sends now-playing titles) is captured in `FFmpegDecoder` at open
time, surfaced through a defaulted `Transport` accessor, shown live in the
sheet, and persisted into the station profile (migration M037 adds
container / sample rate / channels columns).

The request side is already done: FFmpeg sends `Icy-MetaData: 1` by
default, de-interleaves the metadata blocks in `http.c`, and copies
`StreamTitle` into the format context's metadata, raising
`AVFMT_EVENT_FLAG_METADATA_UPDATED` after `av_read_frame` (verified
against the linked FFmpeg 8.x). No loopback proxy, no second connection.

- `FFmpegDecoder`: in the packet-read loop, when the event flag is set,
  read `StreamTitle` from the context metadata, clear the flag, and emit
  on a small optional seam (an `AsyncStream` of title updates the decoder
  vends; local files simply never emit). `AudioEngine` forwards it the
  same way engine events already reach `QueuePlayer`.
- Decoding rule for the bytes: the ICY payload has no specified charset.
  Try UTF-8, fall back to Latin-1, never crash on junk. Coalesce
  consecutive duplicates. Log title changes at debug via `AppLogger`.
- Presentation: now-playing surfaces (transport strip, mini players,
  `MPNowPlayingInfoCenter`) show the stream title as the track line with
  the station name as the artist line while a station plays; queue rows
  keep the station name. An empty, junk, or never-arriving title falls
  back to today's display. Nothing is scrobbled and no history row is
  written; the existing `.internetRadio` early-returns already guarantee
  that, so station idents can never pollute anyone's play counts.
- Station profile capture: on successful open, read the
  `icy_metadata_headers` option (`av_opt_get`, `AV_OPT_SEARCH_CHILDREN`)
  and the measured codec and bitrate from the codec parameters; backfill
  the catalog's empty profile fields (`icy-name`, `icy-genre`, `icy-url`,
  `icy-description`) without overwriting user edits, and stamp
  `last_connected_at`. This also rescues stations imported with junk
  `#EXTINF` names: the first play fixes the name if the user has not
  edited it.

## Non-goals

- No artwork or station logos (ICY `StreamUrl` increasingly carries an art
  URL; a future ADR can use it).
- No play history or scrobbling for stations: `QueuePlayer` already returns
  early for `.internetRadio` by design; unchanged.
- No push to Subsonic servers (SwiftSonic's create/update/delete radio
  endpoints stay unused) and no merging of server stations into the local
  catalog.
- Streams never become playlist entries; playlists stay library-track-only.
- No global-search integration for stations.
- No station directory, no sidecar stats endpoints, no per-station
  loudness, no on-stream honesty analysis: parked below.

## Future work (parked, vetted against the codebase)

Ideas from the radio-detection survey that are real and worth an ADR of
their own, with the existing machinery they would stand on:

- **Directory search**: Radio Browser (`all.api.radio-browser.info`) is a
  keyless community directory of ~50k stations with tags, countries, and
  favicons; etiquette is to POST click counts back. Would slot in beside
  the podcast search UX.
- **Recently played / station stats**: Icecast `status-json.xsl` (whole
  quality ladder, listener counts) and Shoutcast v2 `/played?sid=1`
  (track history). Poll no more often than every 15-30 seconds; these are
  volunteer servers.
- **Per-station loudness pre-gain**: run the existing `EBUR128` on a
  rolling window of the live PCM, cache measured LUFS in the station
  profile, apply as pre-gain on reconnect so switching between library and
  radio never blows anyone's ears out. The DSP chain and the measurement
  code both exist; only the rolling-window wiring is new.
- **Stream honesty**: `ProvenanceAnalyzer` / `SpectralShelf` (ADR-075) on
  live PCM: "claims 320k, spectral shelf says 128k source". Suspected,
  never accused, same stance as ADR-075.
- **HLS stations and DVR windows**: FFmpeg's hls demuxer sits behind the
  existing protocol whitelist so `.m3u8` URLs may already play, but
  variant selection, seekable live windows, and ID3 timed metadata are
  unexplored. Treat as its own ADR if demand appears.

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
  titles). The host-name fallback plus the edit sheet plus ADR-078 slice 5's
  icy-name backfill is the answer; import must never write an empty name.
- ICY titles arrive early: encoders emit the tag when a track is queued,
  so titles lead the audio by roughly 2-20 seconds, and not by a constant
  amount (burst-on-connect). Display-only, so acceptable; do not build
  anything that assumes the title is synchronised.
- The `Artist - Title` split inside `StreamTitle` is a convention, not a
  rule. Do not parse it; display the string whole.
- HLS master playlists pasted as station URLs are unvalidated territory in
  this ADR: they may play via FFmpeg's hls demuxer, or fail oddly. The
  add sheet accepts them (see ADR-078 slice 3) but nothing else special-cases them.
