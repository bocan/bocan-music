# ADR-066: File Serving (tracks, episodes, artwork, lyrics, chapters)

> Depends on: `ADR-060-phone-sync.md`, `ADR-063-http-listener.md` (Router +
> paired-only gating), `ADR-065-manifest.md` (the manifest advertises the
> `sha256`/`relPath` these endpoints honour). Uses **Library** (`SecurityScope`,
> `CoverArtRepository`, `LyricsService`) and **Podcasts** (`DownloadStore`).
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 6 (endpoints), 8
> (lyrics).

## Goal

The five paired-only GET endpoints that stream bytes:

| Endpoint | Source |
|----------|--------|
| `GET /v1/file/track/{trackId}` | track audio via security-scoped bookmark |
| `GET /v1/file/episode/{episodeId}` | downloaded podcast file via `DownloadStore` |
| `GET /v1/artwork/{hash}` | cover-art cache file by content hash |
| `GET /v1/lyrics/{trackId}` | assembled lyrics document (JSON) |
| `GET /v1/chapters/{episodeId}` | cached Podcasting 2.0 chapters JSON |

All resolve by **id/hash through the database**, never by a path from the
request. `Range` and `If-Match` power resumable, cache-correct downloads.

## The cardinal rule (a named gotcha)

**Never serve a file by a path taken from the request.** Every file endpoint
takes an id (or content hash), looks the row up in the database, and resolves the
real filesystem location from stored data (the security-scoped bookmark, the
`DownloadStore` deterministic path, or the cover-art row's `path`). The request
never names a path, so directory traversal is structurally impossible. Keep it
that way: no `{trackId}` is ever concatenated into a filesystem path; a
non-numeric or unknown id is `404`, full stop.

## Track audio: `GET /v1/file/track/{trackId}`

1. Fetch the `Track` by id (`TrackRepository`). Unknown / `disabled` / not in the
   current sync profile -> `404 notFound`.
2. **Re-check staleness before streaming**: if the file's mtime changed since the
   manifest snapshot (or the stored `content_hash` no longer matches a cheap
   check), the client's `If-Match` will already `412`; the server should also
   skip a track whose mtime moved (mid-write file) rather than stream torn bytes.
3. Resolve the file through `SecurityScope` using the track's bookmark:

   ```swift
   // Track.fileBookmark: Data?  (column file_bookmark). SecurityScope is a
   // Library enum: withAccess(_ bookmark:Data, onStaleBookmark:, _ body:).
   try await SecurityScope.withAccess(track.fileBookmark!) { scopedURL in
       try await stream(scopedURL, range: range, etag: track.contentHash)
   }
   ```

   A track with a nil bookmark, or a `LibraryError.bookmarkStale`, -> `404
   notFound` with an `op.failed` log (never a 500 that leaks internals). The
   scoped access must be **balanced**: `SecurityScope.withAccess` handles
   start/stop via `defer`, but the streaming loop inside it must not escape the
   closure with an open file handle. Test the balance under an early client
   disconnect (below).
4. Stream with a **1 MB read loop** (`FileHandle` / `read(upToCount:)`), writing
   to the `NWConnection`, honouring back-pressure (await each `send` completion)
   and `Task.checkCancellation()` each chunk so a disconnect stops the loop
   promptly.

### Range and If-Match

- **`Range: bytes=N-`** (single open-ended range is sufficient): reply `206
  Partial Content` with `Content-Range: bytes N-END/TOTAL` and stream from offset
  N. This is the resume mechanism. Reject multi-range / non-`bytes` with `200`
  full body (or `416` for an out-of-bounds start).
- **`If-Match: <etag>`**: the `ETag` is the manifest `sha256` (`content_hash`).
  If the current file no longer matches (verify via **stored `content_hash` +
  unchanged mtime**, not by rehashing the whole file per request), reply `412
  Precondition Failed`; the client re-fetches the manifest. Set `ETag` on every
  successful response.
- `Content-Type` best-effort from `file_format` (`audio/flac`, `audio/mpeg`, else
  `application/octet-stream`); the client never trusts it for format detection.
- `Content-Length` always set (full length, or the range length for `206`).

## Episode audio: `GET /v1/file/episode/{episodeId}`

`episodeId` is the wire id (`guidHash` = first 32 chars of `SHA-256(guid)`).
Resolve the `(podcastId, guid)` for that hash, confirm `download_state ==
downloaded` and the profile includes podcasts, then serve the file at
`DownloadStore.fileURL(podcastID:guid:mime:)` (Podcasts module,
`~/Library/Application Support/io.cloudcauldron.bocan/Podcasts/Downloads/
<podcastId>/<guidHash>.<ext>`). Downloaded files are in the app container (no
security scope needed), but still resolve by id, never by request path. Same
`Range`/`If-Match`/`ETag` (the manifest `sha256`) rules as tracks. Missing file
-> `404` + `op.failed`.

## Artwork: `GET /v1/artwork/{hash}`

The manifest advertises `artworkHash` (`cover_art_hash`). Serve by hash:

```swift
// Persistence, public: CoverArtRepository.fetch(hash:) -> CoverArt?
guard let art = try await coverArtRepository.fetch(hash: hash) else { return notFound }
// art.path is an absolute file path in the cover-art cache; art.format the type.
```

Read the bytes from `art.path` (cover-art cache, `~/Library/Application Support/
Bocan/CoverArt/...`) and return them with the right `Content-Type` (`art.format`)
and a long `Cache-Control` (artwork is immutable per hash). Unknown hash ->
`404`. No `Range` needed (small); still set `Content-Length`. Do not import the
internal `CoverArtCache` actor (Library-private); go through `CoverArtRepository`.

## Lyrics: `GET /v1/lyrics/{trackId}`

Assemble the same document the lyrics pane would show, via `LyricsService`
(Library actor):

```swift
// LyricsService.lyrics(for: trackId) -> LyricsDocument?
//   LyricsDocument is .synced(lines:, offsetMS:) or .unsynced(text)
```

Return the section-8 JSON:

```json
{ "trackId": 123, "kind": "synced", "text": "[00:12.00]First line\n[00:15.30]Second line" }
```

- `.synced` -> `kind: "synced"`, `text` = the LRC serialization
  (`LyricsDocument.toLRC()`), which is exactly what `lyricsHash` in the manifest
  hashed (ADR-065). `.unsynced` -> `kind: "unsynced"`, `text` = the plain
  text.
- No lyrics from any source -> `404` (the manifest would have `lyricsHash: null`,
  so a well-behaved client will not ask; still handle it).
- The document served here and the one hashed in ADR-065 **must be byte-identical**
  (same serialization), or the client's `lyricsHash` cache invalidation breaks.
  Share one serializer.

## Chapters: `GET /v1/chapters/{episodeId}`

Return the Podcasting 2.0 chapters JSON as cached by the Mac (from the episode's
`chapters_url`, persisted). If chapters were never fetched/cached, `404`. This is
pass-through of cached JSON; do not fetch on demand inside the request (no
outbound network from a serving handler).

**As built (#608).** The first release answered `404` for every episode, because
chapters were fetched on demand and kept only in memory. The cache now exists:

- **Store.** `podcast_episode_chapters` (M054), keyed `(podcast_id, guid)`, holds
  the document verbatim (`content`) and the `chapters_url` it came from
  (`source_url`). `ChaptersRepository` (Persistence) is the only writer. A row is
  *current* only while `source_url` equals the episode's `chapters_url`; every
  read applies that test, so a feed that moves or drops its chapters retires the
  old document.
- **Writer.** `PodcastService.chapters(podcastID:guid:)` stores each document it
  downloads, provided it parses to at least one chapter. The fetch stays
  network-first, and falls back to the stored document when the network fails.
  It runs when the chapter list is shown, and `EpisodeDownloadManager` calls it
  through an App-wired observer when a download finishes, so an episode that was
  never opened on the Mac still has chapters to serve.
- **Route.** `ChapterServing` resolves `episodeId` as the episode file route does
  (downloaded episodes only, profile includes podcasts) and answers `200`,
  `Content-Type: application/json`, body = the stored document unchanged. No
  current document -> `404`. No `ETag`, no `Range` (small, and the phone fetches
  it on demand).
- **Manifest.** `hasChapters` is true exactly when the route has a current
  document to serve, not when the feed merely names a chapters URL.
  `podcast_episode_chapters` is in the generation observer's region, so a newly
  cached document reaches the phone on its next poll. A re-fetch that returns
  the same bytes writes nothing and does not bump the generation.

Not built: a backfill for episodes downloaded before this change. Their chapters
are cached the next time the chapter list is shown on the Mac.

## Concurrency and safety

- All handlers run on the `SyncServer` actor's executor, **off the MainActor**
  (asserted by test). Serving several large files concurrently must not starve
  the UI.
- Every read loop calls `Task.checkCancellation()`; an early client disconnect
  cancels the streaming task, which must still balance the security scope (the
  `withAccess` `defer` handles the stop; the test proves no leak).
- One `SyncServerError` case per failure kind, logged `op.failed` with the id and
  reason, never the resolved path or file bytes.

## Tests

- **`FileServingTests`** (loopback, seeded in-memory DB + temp files):
  - full body download of a track; byte-exact vs the source file.
  - `Range: bytes=N-` -> `206` + correct `Content-Range` + correct tail bytes;
    resume concatenates to the whole file.
  - `If-Match` with the manifest hash -> `200`/`206`; with a stale hash -> `412`.
  - unknown / disabled / out-of-profile id -> `404`.
  - nil-bookmark or stale-bookmark track -> `404` + an `op.failed` log (not 500).
  - **security-scope balance**: instrument start/stop (inject a counting
    `SecurityScope`-like seam or assert via a test hook) and prove they balance
    even when the client disconnects mid-stream.
  - episode download served from `DownloadStore` path; artwork by hash from
    `CoverArtRepository`; lyrics JSON matches the ADR-065 serialization exactly
    (round-trip the hash).
- **No path traversal**: `GET /v1/file/track/..%2f..%2fetc%2fpasswd` and friends
  resolve to "not a valid id" -> `404`; assert no filesystem access with an
  attacker-controlled path.

## Context7 lookups

- use context7: Network.framework NWConnection send receive backpressure large
  file streaming
- use context7: Foundation FileHandle read(upToCount:) offset seek; HTTP Range
  Content-Range 206 If-Match ETag semantics

## Acceptance criteria

- [x] Track/episode full-body and `Range` resume are byte-exact; `If-Match`
      mismatch returns `412`.
- [x] Every file is resolved by id/hash through the DB; the path-traversal test
      proves no request-supplied path reaches the filesystem.
- [x] Bookmark failure returns `404` + `op.failed`, never a 500; security scope is
      balanced under early disconnect (tested).
- [x] Artwork served by hash via `CoverArtRepository`; lyrics JSON byte-matches
      the manifest `lyricsHash` serialization.
- [x] Handlers run off the MainActor; a large concurrent download leaves the test
      harness's main actor responsive.
- [x] `make ... test-sync-server` green; coverage floor met.

## Handoff

ADR-067 brings the whole listener up as a lifecycle-managed actor and
advertises it; at that point a paired phone can walk ping -> manifest -> files
end to end. ADR-069 proves the byte-for-byte round trip against the real
Android client.
