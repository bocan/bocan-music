# Session 5: Subsonic + SyncServer + Podcasts

> Read [README.md](README.md) first. Scope + starting points only.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Modules/Subsonic/Sources` | 11 | ~1.9k | `SubsonicService` actor, capability detection, Keychain creds. |
| `Modules/SyncServer/Sources` | 29 | ~3.2k | Server identity, trusted devices, Bonjour mTLS file server. |
| `Modules/Podcasts/Sources` | 31 | ~4.1k | Feed parsing, episode state, downloads. |

Prereq: Sessions 1 to 4. Gates: `make test-subsonic`, `make test-sync-server`,
`make test-podcasts`.

## Start here (seeded candidates)

- **Subsonic request/response.** Endpoint calls repeat build-URL + auth-params +
  decode + capability-gate. Normalized-diff the service methods for a common
  request core. This is the third HTTP client after Acoustics and Scrobble --
  by now the cross-module shape should be clear; **log it for Session 10** with
  a concrete proposed home (likely a tiny shared HTTP module or a Persistence-
  level client, respecting the DAG).
- **Keychain access.** Credential read/write patterns -- compare against the
  login-keychain conventions in repo memory; confirm one helper, not several.
- **SyncServer identity + trust.** `ServerIdentity`, `TrustedDevices` -- P-256
  key handling and TLS identity plumbing; check for repeated cert/key derivation.
- **Podcasts feed parsing.** FeedKit-based parsing plus the supplementary
  namespace parser (per repo memory, the `podcast:` namespace gap) -- look for
  field-mapping repeated across feed refresh, import, and OPML paths.
- **Episode state + download.** Download queue and state transitions -- compare
  with the Scrobble offline queue (Session 4): if two offline/retry queues are
  near-identical, that is a cross-module candidate.

## Exit criteria

- All three modules triaged; ledger rows for all clusters.
- The HTTP-client cross-module candidate has a concrete proposed resolution for
  Session 10 (home module, interface sketch), not just "defer".
- `make test-subsonic`, `make test-sync-server`, `make test-podcasts`,
  `make lint`, `make build` green.
