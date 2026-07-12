# Phase 22-10: Podcast Artwork over Sync

> Depends on: `phase22-5-manifest.md` (the manifest advertises artwork by content
> hash), `phase22-6-file-serving.md` (`GET /v1/artwork/{hash}` streams cover-art
> by hash through the DB), `phase21-4-subscriptions.md` / `phase21-6-downloads.md`
> (podcast records carry `artwork_url` and a cached `artwork_path`).
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 6 (endpoints) and the
> manifest Podcast object. No protocol change: `Podcast.artworkHash` already
> exists and is optional.

## Goal

Make subscribed shows display their cover art on the paired phone. Today the phone
shows a placeholder for every podcast because the Mac never advertises a podcast
artwork hash, even though a show's art is already cached locally on the Mac.

The whole gap is one deliberate stub in `ManifestBuilder`:

```swift
// Modules/SyncServer/Sources/SyncServer/Manifest/ManifestBuilder.swift:138
// v1: podcast artwork is a local path, not a content hash.
artworkHash: nil,
```

Track and album art are content-hashed into the cover-art store and served at
`GET /v1/artwork/{hash}`. Podcast art lives outside that store as a plain
`artwork_path`, so it has no hash to advertise and no way to be fetched. This
phase gives podcast art a content hash, advertises it, and teaches the existing
artwork endpoint to resolve it, so it rides the exact pipeline album art already
uses.

The Android side is already complete and needs no change: `ManifestPodcast`
carries `artworkHash`, `SyncApplier` stores it on `PodcastEntity`, the sync engine
downloads it from `/v1/artwork/{hash}` into the same artwork store as albums, and
the podcast grid renders it through the same resolver. It only ever receives
`null` today. (The Android continue-listening shelf, which had hardcoded a null
hash, was fixed separately.)

## Non-goals

- No per-episode artwork. Episodes reuse their show's art in v1, matching the
  current phone UI. `ManifestEpisode` gains no artwork field.
- No proxying of the remote `artwork_url`. The phone speaks TLS only to the paired
  Mac and never fetches third-party image hosts; art must come through
  `/v1/artwork/{hash}`.
- No sync-protocol.md change. The `Podcast.artworkHash` field already exists and
  is documented as optional; this phase only starts populating it.
- No new artwork format handling beyond what `CoverArtRepository` /
  `imageMIME(_:)` already support (JPEG, PNG).

## Definitions and contracts

### Podcast artwork hash

A podcast's advertised `artworkHash` is the lowercase hex SHA-256 of the bytes of
its cached artwork file (`artwork_path`), the same hash discipline album cover art
uses. A show with no cached artwork file advertises `nil` (the phone keeps its
placeholder). The hash is stable for identical bytes, so two shows sharing art
de-duplicate on the phone automatically.

### Storage

Add an `artwork_hash TEXT` column to the `podcasts` table (migration), computed
when the show's artwork is first cached and recomputed whenever the feed updates
`artwork_path` to different bytes. This mirrors the episode pattern where the file
content hash is stored at download time (M032), not recomputed on every manifest
build.

### Serving: `GET /v1/artwork/{hash}` resolves podcast art too

`FileServing.artwork(_:)` currently resolves a hash only through
`CoverArtRepository.fetch(hash:)`. Extend it so that a hash the cover-art store
does not know is then looked up against podcasts (`artwork_hash -> artwork_path`),
and served from that path. The cardinal rule from 22-6 still holds verbatim: the
request never names a path; the hash is resolved to a filesystem location through
the database, so traversal stays structurally impossible. An unknown hash is still
`404`.

Order matters only for correctness, not security: try cover-art first (the common
case), then the podcast fallback, then `404`.

### Manifest

`ManifestBuilder` sets `artworkHash: podcast.artworkHash` (the stored column)
instead of the `nil` stub. Nothing else in the Podcast object changes.

## Implementation plan

1. **Migration + record**: add `artwork_hash` to `podcasts`; surface it on the
   `Podcast` record and repository. Commit.
2. **Hashing at cache time**: where the show's artwork is downloaded/cached to
   `artwork_path` (subscription refresh / download pipeline), compute the SHA-256
   and persist `artwork_hash`. Add a one-shot backfill for shows that already have
   an `artwork_path` but no hash (a small pass like the track `content_hash`
   backfill), so existing libraries light up on the next sync without re-fetching
   feeds. Commit.
3. **Manifest**: replace the `artworkHash: nil` stub with the stored hash; the
   generation bumps when a show's `artwork_hash` changes so the phone re-syncs.
   Commit.
4. **Serving**: extend `FileServing.artwork(_:)` with the podcast fallback,
   resolving `artwork_hash -> artwork_path` through the DB and streaming with the
   same headers (`etag`, immutable `cache-control`, `imageMIME`). Commit.

## Context7 lookups

- use context7: CryptoKit SHA256 hashing file Data streaming
- use context7: GRDB add column migration backfill

## Test plan

- **Manifest**: a show with a cached artwork file advertises its SHA-256; a show
  with no artwork advertises `nil`; the hash equals an independent SHA-256 of the
  file bytes.
- **Serving**: `GET /v1/artwork/{podcastHash}` returns the file bytes with the
  correct image MIME and `etag == hash`; an unknown hash is `404`; a cover-art
  hash still resolves through the existing path (no regression).
- **Path safety**: the podcast fallback resolves only via the DB column; a
  request-supplied path can never reach it (reuse the 22-6 traversal test).
- **Backfill**: a library with `artwork_path` set but `artwork_hash` null gets the
  hash populated by the one-shot pass, and the next manifest advertises it.
- **De-dup**: two shows pointing at byte-identical art advertise the same hash.
- **Generation**: changing a show's artwork bytes changes its `artwork_hash` and
  bumps the manifest generation.

## Acceptance criteria

- [x] `podcasts.artwork_hash` exists, is populated at cache time, and is
      backfilled for existing shows.
- [x] `ManifestBuilder` advertises the real podcast artwork hash; shows without
      art advertise `nil`.
- [x] `GET /v1/artwork/{hash}` serves podcast art by hash through the DB, with the
      same headers as cover art, and `404`s an unknown hash; cover art is
      unregressed.
- [x] Path-traversal test still proves no request-supplied path reaches the
      filesystem for the podcast fallback.
- [ ] A paired phone shows real cover art for subscribed shows after one sync,
      with no Android change beyond the already-landed continue-shelf fix.
      (Wire-level behaviour is covered by tests; the on-device pass with a
      paired phone is still to be run.)
- [x] `make ... test-sync-server` green; coverage floor met.

## Gotchas

- **Do not hash on every manifest build.** Hashing every show's art on each
  `/v1/manifest` is wasteful and adds latency to a hot path; hash once at cache
  time and store it, exactly like episode/track hashes.
- **`artwork_path` can be nil or point at a since-deleted file.** A nil path or a
  missing file means `artworkHash: nil` in the manifest (never advertise a hash
  whose bytes cannot be served) and a `file.artwork.missing`-style log on a serve
  miss, `404`, not `500`.
- **Feed art updates.** Shows re-fetch art when the feed changes it; recompute the
  hash when `artwork_path` bytes change, or the phone keeps stale art until the
  next unrelated resync.
- **Keep the cardinal rule.** The podcast fallback must resolve the path from the
  `artwork_hash` column, never from anything in the request. It is a database
  lookup that happens to end in a file read, identical in spirit to the cover-art
  path.
- **MIME.** Reuse `imageMIME(art.format)` semantics; store or infer the podcast
  art format (JPEG/PNG) so the served `content-type` is correct rather than a
  guessed default.

## Handoff

After this phase the manifest carries podcast artwork hashes and the artwork
endpoint serves them, so the existing Android sync pipeline displays show art with
no further phone work. A future phase could add per-episode artwork (a new
`ManifestEpisode.artworkHash`) if feeds that vary art per episode become worth
supporting; this phase intentionally stops at show-level art to match the v1 UI.
