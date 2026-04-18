# Phase 13 — Last.fm & ListenBrainz Scrobbling

> Prerequisites: Phases 0–12 complete. `play_history` and `scrobble_queue` tables exist (Phase 2).
>
> Read `phases/_standards.md` first.

## Goal

Send plays to Last.fm (primary) and ListenBrainz (swappable). Queue offline, retry with backoff, avoid duplicates, honour the classic scrobble rule (≥ 50% or ≥ 4 min, and track ≥ 30s). Love/unlove roundtrip. Settings UI and recent-scrobble view.

## Non-goals

- ListenBrainz-only features (MBID-heavy submissions beyond what Last.fm also accepts) — optional.
- Importing historical scrobbles from Last.fm back into Bòcan — stretch.
- Per-artist blocklists — not in v1 (but design the hook so you can add later).

## Outcome shape

```
Modules/Scrobble/
├── Package.swift
├── Sources/Scrobble/
│   ├── ScrobbleService.swift             # Orchestrator
│   ├── ScrobbleRules.swift               # Eligibility + accumulation
│   ├── Providers/
│   │   ├── ScrobbleProvider.swift        # Protocol
│   │   ├── LastFmProvider.swift
│   │   └── ListenBrainzProvider.swift
│   ├── Auth/
│   │   ├── LastFmAuth.swift              # Desktop auth + session key
│   │   └── ListenBrainzAuth.swift        # User token
│   ├── Queue/
│   │   ├── ScrobbleQueueWorker.swift     # Drains scrobble_queue
│   │   └── RetryPolicy.swift             # Exponential backoff
│   ├── Network/
│   │   ├── HTTPClient.swift              # Stub-friendly wrapper
│   │   └── Reachability.swift
│   └── Errors.swift
└── Tests/ScrobbleTests/

Modules/UI/Sources/UI/Scrobble/
├── ScrobbleSettingsView.swift
├── RecentScrobblesView.swift
└── ConnectSheet.swift
```

## Implementation plan

1. **`Modules/Scrobble` Swift Package**, depends on `Observability`, `Persistence`, `Playback`.

2. **`ScrobbleProvider` protocol**:
   ```swift
   public protocol ScrobbleProvider: Sendable {
       var id: String { get }                        // "lastfm" | "listenbrainz"
       var displayName: String { get }
       func nowPlaying(_ play: PlayEvent) async throws
       func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult]
       func love(track: TrackIdentity, loved: Bool) async throws
       func isAuthenticated() async -> Bool
   }
   ```

3. **`PlayEvent`** — everything a provider could need from a single play:
   ```swift
   public struct PlayEvent: Sendable, Codable, Hashable {
       public let queueID: Int64                // scrobble_queue.id
       public let trackID: Int64
       public let artist: String
       public let albumArtist: String?
       public let album: String?
       public let title: String
       public let duration: TimeInterval
       public let mbid: String?                 // track MBID if known
       public let playedAt: Date                // UTC timestamp of start-of-play
   }
   ```

4. **`ScrobbleRules`**:
   - Eligible if `duration ≥ 30s` AND (`elapsed ≥ 50%` OR `elapsed ≥ 4 min`).
   - `elapsed` excludes time paused; pauses during play are allowed but their durations don't count.
   - Skips (next pressed before threshold) → no scrobble; `skip_count` still updated (already handled in Phase 5's recorder).
   - **One scrobble per play event**; replays count as new events.

5. **Integration with `PlayHistoryRecorder` (Phase 5)**:
   - When the rule becomes true, additionally insert a row into `scrobble_queue` with `submitted=0`.
   - `ScrobbleService` observes `scrobble_queue` (or receives a signal from the recorder) and triggers the worker.

6. **`ScrobbleQueueWorker`**:
   - Drains unsent rows in timestamp order, batching up to 50 per Last.fm request (their limit).
   - Retries with exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s, cap. Capped retries per row at 20.
   - Marks rows `submitted=1` on success; increments `submission_attempts` on failure.
   - Rows with `submission_attempts >= 20` get a `dead=1` flag (add column via migration if not present) and are surfaced in Settings as "failed scrobbles" for manual action (export, delete, retry).
   - Reachability-aware: pauses when offline; resumes on network-up (NWPathMonitor).

7. **Last.fm auth** (`LastFmAuth`):
   - Desktop auth: request a token from `auth.getToken`, open `https://www.last.fm/api/auth/?api_key=<K>&token=<T>` in browser.
   - Poll `auth.getSession` every 5s (bounded wait, 5 min) until the user authorises; store `sk` (session key) and `name` (user name).
   - Signing: MD5 of concatenated sorted params + secret per Last.fm docs.
   - API key + shared secret stored as **build constants**, not user-visible — redacted in logs. For OSS distribution, ship with a project-managed key; note the rate limits.

8. **`LastFmProvider`** endpoints:
   - `track.updateNowPlaying` on track start.
   - `track.scrobble` on eligibility.
   - `track.love` / `track.unlove` for hearts.
   - Accept multiple scrobbles in one request (up to 50 `artist[i]`, `track[i]` param sets).
   - Parse `lfm` response; treat status != ok as error.

9. **`ListenBrainzProvider`**:
   - User provides a user token from their account (stored in the Keychain).
   - POST JSON to `https://api.listenbrainz.org/1/submit-listens` with:
     - `listen_type`: `playing_now` or `single` / `import` for batches.
     - `payload`: array of listens with `listened_at`, `track_metadata`.
   - Love/unlove via feedback endpoint.
   - Same queue/rule/worker.

10. **Provider selection**:
    - Independent on/off toggles per provider. Both can run simultaneously.
    - Each maintains its own submission state per queue row (use two columns `lastfm_submitted`, `listenbrainz_submitted`, or a join table `scrobble_submissions(queue_id, provider_id, status)` — the join table is cleaner; add via migration).

11. **Keychain storage** — `Observability.SecretsStore` or a new `Scrobble.Credentials` helper wrapping the macOS Keychain via `Security.framework`. Never persist session keys or user tokens to `settings` / files.

12. **UI**:
    - **`ConnectSheet`** — step-by-step: explain → open auth URL in browser → waiting state → success.
    - **`ScrobbleSettingsView`** — toggles, connected-account names, disconnect, "resubmit dead queue", "export queue to CSV".
    - **`RecentScrobblesView`** — last 50 entries, with status (queued / sent / failed), timestamp, artist/title. Filter by provider.
    - Global indicator: a small icon in the transport strip when a scrobble is pending/sending; tap to open the recent view.

13. **Deduplication**:
    - Same `(track_id, played_at)` pair written twice → second insert ignored (unique constraint on `(track_id, played_at)`). Add via migration if not present.
    - Provider `submit` never resubmits rows with `submitted=1`.

14. **Retroactive scrobbles** (nice-to-have): from `play_history` rows with no `scrobble_queue` entry (e.g. during offline install), allow user to submit older plays via "Backfill" in settings (capped to 14 days, which is Last.fm's cutoff).

## Context7 lookups

- `use context7 Last.fm API auth.getToken auth.getSession scrobble`
- `use context7 Last.fm API signature MD5 parameters`
- `use context7 ListenBrainz API submit-listens payload`
- `use context7 macOS Keychain Security framework Swift`
- `use context7 Network NWPathMonitor reachability Swift`
- `use context7 Swift URLSession retry exponential backoff`

## Dependencies

None new.

## Test plan

### Rules

- Track of 29s, played fully → ineligible.
- Track of 60s, played to 0:29 → ineligible.
- Track of 60s, played to 0:31 → eligible.
- Track of 600s, played to 4:00 → eligible.
- Pause for 5 min mid-play, resume, finish → eligible (not double-counted).

### Providers (mocked HTTP)

- **Last.fm**:
  - Successful `scrobble` parsed, rows marked sent.
  - `9` error (invalid session) → mark credentials invalid, surface a banner.
  - Rate limit (`29`) → back off, don't mark sent.
  - Signature generator produces the expected MD5 for a fixture param set (sorted, joined with the shared secret).
- **ListenBrainz**:
  - 200 response → rows marked sent.
  - 429 → honour `Retry-After`.
  - 401 → clear token, notify.

### Worker

- Offline → queue grows, no submission attempts (reachability mock).
- Back online → drains queue in chronological order.
- 5 queued rows fail permanently → dead flag set after max attempts; no further attempts.

### Keychain

- Store, read, delete round-trips; round-trip survives simulated app restart.
- Denied-by-user path (user refuses keychain prompt) surfaces a clear error.

### Duplicates

- Inserting the same `(track_id, played_at)` twice yields one queue row.

### UI

- Connect flow end-to-end with mocked auth.
- Recent view shows correct statuses.
- "Disconnect" clears keychain credentials and switches the toggle off.

## Acceptance criteria

- [ ] Connect Last.fm account; play some tracks; they appear on the user's profile within a minute.
- [ ] Disconnect / reconnect is clean.
- [ ] Offline play queues; comes back online and drains without duplicates.
- [ ] Dead-letter queue visible and actionable.
- [ ] ListenBrainz works as an alternative (or in parallel).
- [ ] Hearts round-trip.
- [ ] Credentials stored in Keychain only.
- [ ] 80%+ coverage on rules/workers/providers.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Scrobble rule "playback time"** excludes pauses. The recorder from Phase 5 tracks that already; ensure `PlayEvent.playedAt` is the *original* track start time, not the resumed timestamp (Last.fm expects when the play *began*).
- **Clock skew**: use UTC, integer Unix seconds. Last.fm rejects timestamps more than 14 days in the past or in the future.
- **API key in the binary**: unavoidable. Treat it as a budget to protect with request shaping — not a secret. Document.
- **Now Playing** updates every track start — but some users may play through a ton of 30s previews. Throttle to 1 per 5s to avoid spam.
- **Signature ordering**: Last.fm requires params sorted by name (utf-8), concatenated `kv` (no separators), then the shared secret, then MD5. Any deviation produces `13 Invalid method signature`.
- **Empty album** is permitted and common (e.g. singles without album). Providers must handle missing album gracefully.
- **Love/unlove**: provider-specific. For Last.fm, love is stored server-side; for ListenBrainz, it's a feedback record. Bòcan's own `tracks.loved` is the local truth; syncing one-way (app → service) is safer than bidirectional.
- **NWPathMonitor** emits states on a background queue; hop to the actor.
- **Retries on 429**: honour `Retry-After` header or default to the current backoff.
- **Keychain access on first launch** might prompt the user — schedule Keychain reads outside hot paths so the prompt doesn't block playback.
- **User tokens in logs**: redact by key. If you log an entire request, scrub `Authorization` headers.
- **Multiple workspaces / instances**: if the user runs two copies of Bòcan simultaneously (don't), scrobble duplicates can appear. Enforce a single-instance policy in Phase 16 or accept the trade-off.
- **"Recently listened" backfill**: Last.fm allows backdated scrobbles within 14 days. Respect that window; older plays are silently rejected.

## Handoff

Phase 14 (Playlist I/O) expects:

- `tracks.last_played_at`, `play_count`, etc. remain authoritative in the DB for export purposes.
- No scrobble module side-effects during import/export (they're orthogonal).
