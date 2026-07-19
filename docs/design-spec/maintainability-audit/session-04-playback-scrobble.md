# Session 4: Playback + Scrobble

> Read [README.md](README.md) first. Scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Modules/Playback/Sources` | 19 | ~4.1k | QueuePlayer actor, queue/history/shuffle, schedulers, sources, sleep timer, persistence. |
| `Modules/Scrobble/Sources` | 19 | ~2.7k | Last.fm / ListenBrainz / Rocksky providers + offline queue. |

Prereq: Sessions 1 to 3. Gates: `make test-playback`, `make test-scrobble`.

## Start here (seeded candidates)

- **Scrobble providers (high-value).** Last.fm, ListenBrainz, and Rocksky are
  three providers behind one protocol -- a textbook parallel-types cluster.
  Normalized-diff them: request signing, payload building, response parsing, and
  error mapping are likely 3x near-duplicates. Strong "consolidate" candidate for
  the shared parts (e.g. a common request/submit skeleton with per-provider
  hooks) -- **but** apply the coupling test: providers with genuinely different
  auth/payloads should keep those parts distinct. Share the skeleton, not the
  provider-specific bodies.
- **The offline scrobble queue.** Enqueue/flush/retry logic -- confirm it is not
  partly re-implemented per provider.
- **Schedulers.** `GaplessScheduler` vs `CrossfadeScheduler` -- normalized-diff
  for shared scheduling/lookahead plumbing; keep the timing math distinct.
- **`PlayableSource` handling.** The `.localBookmark` / `.subsonic` /
  `.internetRadio` branches -- look for per-case boilerplate (resolve, open,
  cleanup) that a protocol method would carry instead of a switch repeated in
  several places.
- **HTTP client shape.** Scrobble providers repeat request/decode/error-map like
  Acoustics (Session 2). **Defer the shared client to Session 10.**

## Exit criteria

- Playback + Scrobble fully triaged; ledger rows for all clusters.
- Scrobble-provider cluster has an explicit decision (which parts shared, which
  kept distinct, with the rubric reasoning).
- HTTP client shape logged as **deferred -> Session 10**.
- `make test-playback`, `make test-scrobble`, `make lint`, `make build` green.
