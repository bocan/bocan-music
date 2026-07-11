# Phase 22-5: SyncProfile + ManifestBuilder + Generation

> Depends on: `phase22-0-overview.md`, `phase22-2-identity-trust.md` (the M031
> tables), `phase22-3-http-listener.md` (the `Router` + `/v1/ping`).
> First slice to depend on **Library** (smart-playlist compiler, `LyricsService`)
> and **Podcasts** (episode state).
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 6 (ping/manifest), 7
> (manifest shape), 8 (lyrics). Shared fixture: `manifest-small.json`.

## Goal

The content plane. Three things:

1. `SyncProfile` model + persistence (what the phone may see).
2. `ManifestBuilder`: one consistent GRDB read producing the manifest DTOs
   **value-identical** to the Android golden `manifest-small.json`.
3. The generation counter: a persisted integer bumped by a debounced
   `LibraryChangeObserver`, plus the stable `serverId`, both in `sync_meta`. Wire
   `GET /v1/manifest` and finalize `GET /v1/ping`.

This slice carries the second cross-repo compatibility proof (the first was the
pairing vectors in 22-1): the Mac must produce a manifest whose values match the
Android fixture field-for-field.

## Impedance mismatches (read before coding: the Mac schema differs from the wire)

The wire DTOs in `sync-protocol.md` section 7 were written to the phone's ideal
shape. Several fields do **not** map 1:1 to the Mac's `tracks` schema. These are
the places a naive implementation gets it wrong:

1. **`relPath` is derived, not stored.** The `tracks` table stores
   `file_url: String` (an absolute file URL, column `file_url`, NFC-normalized,
   UNIQUE) and a `file_bookmark: Data?`. The wire wants a sanitized relative path
   (`no leading /`, `no ..`, forward slashes, NFC). Derive it: resolve the track's
   path relative to the library root (from `LibraryRootRepository`), strip the
   root prefix, sanitize. A track outside every known root, or one whose relative
   path cannot be formed safely, is **excluded** from the manifest (log
   `op.skipped`).

2. **CUE clips key off a URL, not a track id.** The Mac has no `sourceTrackId`.
   `tracks` stores `start_offset_ms`, `end_offset_ms`, and
   `source_file_url: String?` (migration `M013_CueVirtualTracks`). The wire
   `clip` DTO is `{ sourceTrackId, startMs, endMs }`. To emit it: look up the
   track whose `file_url == source_file_url` (the CUE parent) to get its `id`,
   then `clip = { sourceTrackId: parent.id, startMs: start_offset_ms, endMs:
   end_offset_ms }`. Per the wire contract the clip's own `relPath`/`size`/
   `sha256` duplicate the parent's (the phone downloads the source once). If the
   parent is not in the manifest (out of profile), drop the clip child too.

3. **`sha256` (content hash) is nullable on the Mac.** `tracks.content_hash:
   String?`. The wire requires `sha256` (it is the `ETag` and the `If-Match`
   basis for resumable download). A track with `content_hash == nil` **cannot be
   served safely** and is excluded from the manifest (log `op.skipped` with a
   count). Do not invent a hash at build time; the library owns hashing.

4. **`lyricsHash` is computed, not stored.** There is no lyrics column on
   `tracks` and no lyrics hash anywhere. Lyrics live in a separate `lyrics` table
   and are assembled by `LyricsService` (user > sidecar > embedded > lrclib). To
   emit `lyricsHash`: assemble the document the lyrics endpoint would serve
   (phase 22-6 serves the same one), serialize it canonically (LRC for synced,
   plain text for unsynced), and hash that. This is per-track work; cache it
   keyed by `(trackId, generation)` so a manifest rebuild at the same generation
   does not re-assemble every track's lyrics. `lyricsHash == null` when the track
   has no lyrics from any source.

5. **Artist/album/albumArtist names are not denormalized on `tracks`.** Resolve
   `artist_id` -> `Artist.name`, `album_id` -> `Album.title`, `album_artist_id`
   -> `Artist.name`. Do it inside the one `db.read` with a join or a prefetched
   id->name map, not N+1 queries.

6. **Playlist artwork is a path, not a hash.** `playlists.cover_art_path` is a
   file path; the wire `Playlist.artworkHash` wants a content hash. For v1 emit
   `artworkHash: null` for playlists (the phone falls back to a computed cover),
   unless a hash is cheaply available. Document the choice; do not block on it.

7. **ReplayGain columns are individually nullable.** `replaygain_track_gain`,
   `_track_peak`, `_album_gain`, `_album_peak` are separate `Double?`. Emit the
   wire `replayGain` object only when at least the track gain is present; omit or
   null the object otherwise (additive-field rule: the phone ignores absence).

Each of these is a test in `ManifestBuilderTests`.

## SyncProfile

```swift
public enum SyncProfile: Sendable, Codable, Equatable {
    case everything(includePodcasts: Bool)
    case selected(playlistIds: [Int64], includePodcasts: Bool)
}
```

Persisted as the `profile_json` blob in the `sync_profile` singleton row (M031).
`SyncProfileRepository: Sendable` over the `Database` actor:

```swift
public struct SyncProfileRepository: Sendable {
    public func current() async throws -> SyncProfile     // defaults to .everything(includePodcasts: true) if unset
    public func set(_ profile: SyncProfile) async throws  // bumps generation (see below)
}
```

Profile membership rules for `ManifestBuilder`:

- `.everything`: every eligible track (see exclusions above).
- `.selected(playlistIds:)`: the union of tracks reachable from the chosen
  playlists. For a **folder**, include its descendants' tracks. For a **smart**
  playlist, evaluate it (below) and include its result tracks. The manifest's
  `tracks` array is exactly this set; playlists' `trackIds` are filtered to this
  set.

## ManifestBuilder

`public struct ManifestBuilder: Sendable`, constructed with the repositories +
`LyricsService` + a lyrics-hash cache. One method, one `db.read`:

```swift
public func build(profile: SyncProfile, serverId: String, serverName: String,
                  generation: Int, generatedAt: Date) async throws -> Manifest
```

Rules (per `sync-protocol.md` section 7):

- **One `db.read` closure** for the whole snapshot so it is internally
  consistent (the `Database` actor's `read` runs all fetches on one connection).
  Lyrics-hash assembly may need `LyricsService` calls outside that closure; do
  those against the same snapshotted track set and treat a mid-build change as
  the next generation's problem (the generation counter + `If-Match` cover it).
- **Tracks**: `disabled == false`, within profile, with a non-nil `content_hash`
  and a formable `relPath`. Map every field per section 7:
  `id, relPath, size (file_size), sha256 (content_hash), format (file_format),
  durationMs (duration * 1000, integer), title, artist(+Id), albumArtist(+Id),
  album(+Id), trackNumber/trackTotal, discNumber/discTotal, year, genre,
  composer, bpm, rating (0-100), loved, sampleRate, bitDepth, bitrate,
  channelCount, isLossless, replayGain{...}, artworkHash (cover_art_hash),
  lyricsHash (computed), clip (null for normal tracks, else the resolved DTO)`.
- **Smart playlists**: evaluate through the existing criteria compiler at build
  time and emit ordered id lists. Use `CriteriaCompiler.compile(criteria:...)`
  (in `Library`, `SmartPlaylists/Compiler/CriteriaCompiler.swift`) to get the
  `selectSQL` + arguments, or call `SmartPlaylistService.tracks(for:)` for the
  materialized ordered list. Filter the resulting ids to tracks present in the
  manifest (a smart list may reference out-of-profile tracks; drop them, do not
  add them).
- **Manual playlists**: ordered ids via `PlaylistRepository.fetchTrackIDs(
  playlistID:)` (`ORDER BY position`), filtered to the manifest set. **Folders**:
  `kind == folder`, empty `trackIds`, carry `parentId`/`sortOrder` for hierarchy.
- **Podcasts** (only when the profile includes podcasts): shows with at least one
  **downloaded** episode in profile; episodes only where `download_state ==
  downloaded` (`EpisodeStateRepository.fetchByDownloadState([.downloaded])` or a
  per-show `fetchAll`); `playPositionMs` (`play_position * 1000`) / `playState`
  from `podcast_episode_state` at build time; `relPath` mapped from the Downloads
  layout: `Podcasts/<podcastId>/<guidHash>.<ext>` where `guidHash` is the first
  32 chars of `SHA-256(guid)` (this equals the wire episode `id`, and matches
  `DownloadStore.fileURL`); `size`/`sha256` from the downloaded file
  (`download_bytes` + a stored/derived hash). `playbackSpeed` from the per-show
  setting.

### JSON encoding parity

Encode `Manifest` with a `JSONEncoder`. Values must match `manifest-small.json`
field-for-field; key order may differ (the phone parses by key). Watch the
lossy conversions: `durationMs` is an integer millisecond count, timestamps are
ISO-8601 UTC (`generatedAt`, `publishedAt`), `rating` is 0-100, booleans are JSON
booleans. The parity test decodes both the Mac output and the fixture into the
DTO structs and compares structurally (so key order and whitespace are ignored,
values are not).

## Generation counter + serverId (`sync_meta`) + change observer

`SyncMetaRepository: Sendable` over the singleton `sync_meta` row:

```swift
public struct SyncMetaRepository: Sendable {
    public func serverId() async throws -> String        // mint + persist a UUID on first read
    public func generation() async throws -> Int
    public func bumpGeneration() async throws -> Int      // atomic increment, returns new value
}
```

`serverId` is minted once and stable for the life of the Mac's library DB (the
phone keys its local store on it).

`LibraryChangeObserver` (an actor in `SyncServer`) bumps generation on relevant
change, **debounced 5 s** so a burst of edits bumps once:

- Subscribe to GRDB `ValueObservation` over the regions that affect a manifest:
  `tracks`, `playlists`, `playlist_tracks`, `podcast_episode_state` (download +
  position/state), and the `sync_profile` row. Use
  `Database.observe(regions:value:)` (respect the `requiresWriteAccess = true`
  caveat) or compose the per-repository observers already in the codebase
  (`TrackRepository.observe`, `EpisodeStateRepository.observe`,
  `SmartPlaylistService.observe`).
- Debounce: collapse events within a 5 s window into a single `bumpGeneration()`.
  Use an injected clock so tests do not wait real time.
- **Profile edits bump too**: `SyncProfileRepository.set` triggers the observer
  (or bumps directly). A profile change with an unchanged library must change
  `generation` so the phone re-syncs. This is a named gotcha.

`GET /v1/ping` returns `{ protocolVersion: 1, serverId, generation }` from
`SyncMetaRepository`. `GET /v1/manifest` (paired only) builds and returns the
manifest; honour `Accept-Encoding: gzip` by gzipping the response body (still set
`Content-Length` on the compressed bytes). May respond `503 busy` +
`Retry-After` if a library scan is mid-flight and the manifest would be torn
(optional in v1; document if deferred).

## Tests

- **`ManifestBuilderTests`** with fixture in-memory `Database`s: profile filtering
  (selecting a playlist drops out-of-profile smart-list members); clip tracks
  resolve `source_file_url` to the parent id and duplicate its bytes; a null
  `content_hash` track is excluded (with a skip count); `relPath` derivation and
  sanitization; lyricsHash computed and stable; podcast state snapshot; ReplayGain
  emitted only when present.
- **Golden parity**: build a manifest from the same fixture library the Android
  `manifest-small.json` describes and assert structural value-equality with the
  committed fixture (copied into `Tests/SyncServerTests/Fixtures/`).
- **Stability**: identical DB state + same generation -> identical manifest bytes.
- **Generation**: a track edit bumps generation once after the 5 s debounce
  (injected clock); a `sync_profile` change bumps it; N edits within the window
  bump once; `serverId` is stable across calls.

## Context7 lookups

- use context7: GRDB ValueObservation multiple regions tracking debounce
  requiresWriteAccess
- use context7: Foundation JSONEncoder deterministic output; gzip Data compression
  (libcompression / zlib) Content-Encoding

## Acceptance criteria

- [x] Manifest is value-identical to `manifest-small.json` for the shared fixture
      (structural compare); the Android `SyncApplier` accepts it unmodified
      (verified in 22-9).
- [x] Every impedance mismatch above has a passing test (relPath, clip via
      source_file_url, null-hash exclusion, computed lyricsHash, name joins,
      ReplayGain nullability).
- [x] Profile filtering: selected playlists drop out-of-profile smart members;
      podcasts included only when the profile opts in and only downloaded
      episodes appear.
- [x] Generation bumps once per debounced burst and on profile edits; `serverId`
      stable; `/v1/ping` reflects both.
- [x] `GET /v1/manifest` is paired-only, gzips on request, and is built from one
      consistent read.
- [x] `make ... test-sync-server` green; coverage floor met.

## Handoff

Phase 22-6 serves the bytes the manifest describes (tracks/episodes/artwork/
lyrics/chapters) and relies on `sha256`/`relPath` being exactly what the manifest
advertised (`If-Match` uses the manifest `sha256`). Phase 22-8's profile editor
writes through `SyncProfileRepository.set` and shows a size estimate summed from
the in-profile track/episode `size` fields.
