# Phase 22: Phone Sync Server - Overview and Cross-Phase Contract

> Prerequisites: Phases 0 to 21 complete. The module DAG, the GRDB `Database`
> actor + numbered-migration + repository pattern, the `SecurityScope` helper
> (Phase 3), the cover-art cache, the smart-playlist criteria evaluator, the
> `Podcasts` module (subscriptions, `podcast_episode_state`, `DownloadStore`),
> the `AppLogger` facade, the `L10n` localization workflow, and the Settings
> window all exist.
>
> Read `docs/design-spec/_standards.md` first, then this file. **This file is
> the contract.** Phases 22-1 through 22-9 each implement one slice of it; read
> this overview before starting any of them so the shared types, table shapes,
> endpoint behaviour, and trust model line up.
>
> **This phase has a second binding document that lives in the sibling repo:**
> `../bocan-music-android/docs/design-spec/sync-protocol.md` is the normative
> wire contract, shared byte-for-byte with the Android client. Where this file
> and `sync-protocol.md` describe the same bytes, `sync-protocol.md` wins;
> behaviour changes require editing that file first (in both repos) and bumping
> `protocolVersion`. The Android-side companion spec
> `../bocan-music-android/docs/design-spec/phase-mac-1-sync-server.md` is the
> brief this group implements; this Phase 22 group is the Mac-repo expansion of
> it.

## What this is

The Mac side of Bòcan Phone Sync. A toggle in Settings starts a mutual-TLS
HTTP server advertised over Bonjour on the local network. A phone discovers the
Mac, pairs once using a six-digit code shown on the Mac's screen, and thereafter
connects over pinned mutual TLS to pull a manifest describing a chosen subset of
the library and download the files. Serving is **read-only** over the library;
this feature writes nothing to tracks, playlists, or podcasts, ever.

The whole design point, and the reason the protocol contract lives in the
Android repo, is that both sides implement the same frozen document
independently and prove compatibility through shared fixtures (pairing golden
vectors, a golden manifest). We are not waiting on the Android client to build
this: the wire contract is committed and stable, and the shared fixtures already
exist. The only end-stage dependency is the final real-device end-to-end run,
which needs the Android pairing + sync engine (its phases 02 and 03) runnable;
everything up to that is provable here against fixtures and loopback TLS.

## The user's brief, reviewed

Bòcan is the source of truth. One Mac, one or more phones. Concretely:

1. A **Phone Sync** pane in Settings with an enable toggle (default off).
2. A **sync profile**: what gets synced. Everything, or a chosen set of
   playlists (and, transitively, their tracks); a podcasts on/off toggle; a
   rough size estimate.
3. A **Pair a phone** button that puts the Mac in pairing mode for 120 s and
   presents a sheet showing a large six-digit code, then a final human
   confirmation ("Pair with '<device>'? Only accept if the phone shows
   Paired.").
4. A **paired devices** list (name, paired date, Revoke).
5. Bonjour-advertised HTTPS serving of the manifest and files, so a paired phone
   can converge on the chosen subset.

Deliberate refinements (do not drop one without unravelling the rest):

- **One way, forever.** No phone-to-Mac data flow of any kind: no play counts
  back, no positions back. The only phone-to-Mac traffic is HTTPS requests. This
  is a security and simplicity property, not a v1 shortcut.
- **LAN only.** No WAN, relay, or cloud transport.
- **A new `SyncServer` SPM module.** It reads the library through existing
  repositories and serves bytes; it never decodes audio, never mutates state.
- **Separate identity from the (unbuilt) Phase 18 remote-control server.** Phase
  18 is a control plane with its own protocol; it is not implemented in this
  repo yet (`Modules/Remote` does not exist). SyncServer is a separate listener
  with a separate TLS identity, a separate Bonjour service, and a separate trust
  store. Do not merge them. If Phase 18 ever lands, the Bonjour/TLS/HTTP
  primitives are candidates for a shared lower-level helper; note them, do not
  pre-factor.
- **Read-only serving through `SecurityScope`.** Every file is resolved by id
  through the database and its security-scoped bookmark, inside a balanced
  scope. The request never names a path, so traversal is structurally
  impossible.

## Relationship to the two repos and the shared fixtures

Three artifacts are shared with `../bocan-music-android` and are the proof of
cross-repo compatibility. Two are already committed there; one is generated and
must be committed on both sides before this group ships.

| Artifact | Android home | Mac home (this group) | Status |
|----------|--------------|-----------------------|--------|
| `sync-protocol.md` | `docs/design-spec/sync-protocol.md` | referenced in place; do not fork | committed, stable |
| `pairing-vectors.json` | `core/sync/src/test/resources/fixtures/pairing-vectors.json` | copied byte-identical into `Modules/SyncServer/Tests/SyncServerTests/Fixtures/` (phase 22-1) | generated; commit on both sides |
| `manifest-small.json` | `core/persistence/src/test/resources/fixtures/manifest-small.json` | copied into `Modules/SyncServer/Tests/SyncServerTests/Fixtures/` (phase 22-5) | committed |

Rules for the shared fixtures:

- **Never hand-edit** a shared fixture in only one repo. The pairing vectors are
  regenerated by `../bocan-music-android/scripts/gen-pairing-vectors.py`; if the
  pairing math ever changes (it should not, section 4 of the protocol is
  frozen), regenerate and commit in both repos in the same change.
- The golden manifest is produced by the Android side from its DTOs. The Mac
  `ManifestBuilder` must be able to produce a **field-for-field value-identical**
  manifest for the same fixture library (key order may differ, values must not).
  Phase 22-5 owns that parity test.

## How Phase 22 is split

Large, so it is broken into nine implementable slices plus this overview. Each
slice is self-contained enough to hand to a single session but shares the types
and contracts defined here. Build them in order; the "Depends on" line at the
top of each file names its hard prerequisites.

| File | Slice | Module(s) touched |
|------|-------|-------------------|
| `phase22-0-overview.md` | This contract (read first) | - |
| `phase22-1-pairing-code.md` | `PairingCode` + golden vectors (test-first) | SyncServer |
| `phase22-2-identity-trust.md` | `ServerIdentity` (Keychain P-256) + `TrustedDevices` (migration) | SyncServer, Persistence |
| `phase22-3-http-listener.md` | `HttpConnection` + `Router` + `NWListener`/TLS verify block + `/v1/ping` | SyncServer |
| `phase22-4-pairing-ceremony.md` | `PairingSession` + `/v1/pair/*` + pairing-mode | SyncServer |
| `phase22-5-manifest.md` | `SyncProfile` + `ManifestBuilder` + generation counter + change observer | SyncServer, Persistence |
| `phase22-6-file-serving.md` | `FileServing` (Range/If-Match) + artwork/lyrics/chapters endpoints | SyncServer |
| `phase22-7-lifecycle-bonjour.md` | `SyncServer` actor lifecycle + Bonjour + app wiring + sleep/wake | SyncServer, App |
| `phase22-8-settings-ui.md` | Settings pane + pairing sheet, localized, snapshot-tested | UI, App |
| `phase22-9-docs-e2e.md` | README + website + cross-repo end-to-end + acceptance sweep | docs |

MVP is 22-1 through 22-8 (a working, paired, end-to-end sync). 22-9 is the
documentation and cross-repo verification sweep that makes the phase "done" per
the standards, and cannot fully close until the Android client is runnable.

The cross-repo compatibility proof lands early on purpose: phase 22-1 makes the
Mac reproduce the Android pairing golden vectors before either side talks to the
other, and phase 22-5 makes the Mac reproduce the golden manifest. If those two
fixtures are green, the two implementations agree on the two hardest-to-debug
parts of the protocol.

## Non-goals

- Any phone-to-Mac write path. Play counts, positions, ratings: they flow Mac to
  phone only.
- WAN / relay / cloud / internet-facing serving. LAN only, no `0.0.0.0` exposure
  beyond the local interfaces.
- Merging with, or reusing the identity/port/trust store of, the Phase 18
  remote-control server.
- Streaming-while-downloading semantics or any audio decoding. We serve bytes
  with `Range`; we never open an `AVAudioFile`.
- Pagination of the manifest. One snapshot document, gzip when asked (protocol
  section 7).
- Editing the sync profile from the phone. The Mac owns the profile.

## Module placement in the DAG

Add one module. It sits at the same tier as the other UI-feeding feature
modules, below `UI`:

```
Observability, Persistence, Library, Podcasts  ->  SyncServer  ->  UI  ->  App
```

`SyncServer` depends on:

- **Persistence** for the track / playlist / podcast repositories, the `Database`
  actor, and the new sync tables (migration M031).
- **Library** for the `SecurityScope` helper (resolving track bookmarks) and the
  cover-art cache.
- **Podcasts** for downloaded-episode paths (`DownloadStore`) and the episode
  state read model.
- **Observability** for `AppLogger`.

`SyncServer` must **not** import `UI`, `App`, `Playback`, `AudioEngine`,
`Scrobble`, `Subsonic`, `Metadata`, or `Acoustics` directly. Lyrics assembly and
any metadata it needs are reached through Persistence-backed repositories or a
small App-injected seam, not by importing those feature modules. `UI` gains a
dependency on `SyncServer` for the settings surface. `App` wires the server into
the launch lifecycle and injects any seams.

Wiring to update (do these in phase 22-2 when the module first exists, and again
in 22-7/22-8 as the edges appear):

- **`_standards.md`**: add `SyncServer` to the "Current internal-module
  dependencies" table, and add `SyncServer` to `UI`'s depends-on row.
- **`CLAUDE.md`**: update the DAG diagram and the module table.
- **`project.yml`**: add `Modules/SyncServer` to the `packages:` block and link
  it into the `UI` target; run `make generate`.
- **`Makefile`**: add a `test-sync-server` target mirroring the other per-module
  SPM test targets, and a per-module coverage-floor entry in the `coverage-all`
  machinery.
- **`Modules/Observability/Sources/Observability/LogCategory.swift`**: add a
  `sync` case to the `LogCategory` enum (the current list is `app, audio,
  library, metadata, persistence, ui, network, playback, podcasts, scrobble,
  subsonic`). Update the category list in `_standards.md` and `CLAUDE.md`.

## Security model (the spine)

This mirrors `sync-protocol.md` sections 2 to 4. Read that document for the
byte-level detail; this is the Mac-side summary the slices assume.

### Identity

Each device has, created once, a P-256 (secp256r1) key pair and a self-signed
X.509 certificate:

- Subject/issuer CN: `bocan-mac-<8 random hex>`, 25-year validity, no renewal
  path (repairing is the recovery story).
- The Mac private key lives in the login Keychain via `SecIdentity`; the cert is
  stored alongside.
- **Fingerprint** = lowercase hex SHA-256 of the certificate's DER encoding.
  Exposed for the Bonjour TXT record (`fp`) and the pairing math.

Owned by `ServerIdentity` (phase 22-2). This is a **separate** identity from any
future Phase 18 remote-control identity.

### TLS

`NWListener` with `NWProtocolTLS.Options`:

- TLS 1.3 minimum (1.2 only if the stack cannot be forced; log a warning).
- Local identity set from `ServerIdentity`; the server always presents its cert
  and always requests a client certificate.
- The `sec_protocol_options` verify block:
  - **In pairing mode**: accept any client cert, but record its DER + fingerprint
    on the connection so the ceremony can bind it.
  - **Outside pairing mode**: pass only connections whose client-cert
    fingerprint is in `TrustedDevices`; reject everyone else at the TLS layer.
    Revocation therefore takes effect on the very next connection.
- No hostname verification, no CA chains, no system trust store. The pin is the
  whole trust decision.

Advertising shares the listener's lifecycle via its `service` (Bonjour), so
"advertising" and "listening" cannot drift apart.

### Pairing ceremony

Server side of `sync-protocol.md` section 4. The six-digit code is **derived
from both certificate fingerprints plus both nonces**, so it is a verification
code, not a secret: a man-in-the-middle that terminates TLS on one side computes
a different code, and the code the user reads off the Mac fails on the phone.

- `POST /v1/pair/start`: phone sends `{protocolVersion, deviceName, noncePhone}`;
  Mac replies `{protocolVersion, serverName, nonceMac, sessionId}`. Each side
  takes the peer cert from the TLS layer (never from JSON) and computes the
  fingerprint.
- Both sides compute the code from the frozen formula in section 4 (see phase
  22-1 for the exact bytes and `PairingCode`).
- The Mac displays the code; the user types it into the phone; the phone
  compares.
- `POST /v1/pair/confirm`: phone sends `{sessionId, proof}` where
  `proof = HMAC-SHA256(key = code-as-ASCII, msg = sessionId-as-ASCII)`. The Mac
  verifies (it knows the code), then shows the **final human confirmation sheet**
  and, on Trust, persists `{fpPhone, certDER, deviceName, pairedAt}` and replies
  `{status: "paired", serverId}`.
- Rate limits: 3 bad proofs or 120 s kills the session; pairing mode auto-exits
  on success or timeout. The `pm` TXT flag must always revert to `0`, including
  on every error path.

The final human click on the Mac is part of the security design (a one-sided
MITM produces a visible asymmetry). Do not remove it.

## Shared value types (referenced across slices)

Canonical homes noted. Other slices consume them as named. All are `Sendable`.
Field names on the manifest DTOs are fixed by `sync-protocol.md` section 7; do
not rename them.

```swift
// SyncServer / Identity (phase 22-2)
public struct ServerFingerprint: Sendable, Hashable {
    public let hex: String            // lowercase hex SHA-256 of cert DER, 64 chars
}

// SyncServer / Trust (phase 22-2), persisted in trusted_devices
public struct TrustedDevice: Sendable, Identifiable {
    public let fingerprint: String    // lowercase hex SHA-256 of the phone cert DER (PK)
    public let certDER: Data          // the pinned client certificate
    public let deviceName: String     // human name from pairing
    public let pairedAt: Date
}
```

```swift
// SyncServer / Manifest (phase 22-5). Shape is fixed by sync-protocol.md s7.
// Encoded with a JSONEncoder whose output must be value-identical to the
// Android golden manifest for the same fixture DB.
public struct Manifest: Sendable, Codable {
    public var protocolVersion: Int   // 1
    public var serverId: String       // uuid, stable per Mac
    public var serverName: String
    public var generation: Int
    public var generatedAt: String    // ISO-8601 UTC
    public var tracks: [ManifestTrack]
    public var playlists: [ManifestPlaylist]
    public var podcasts: [ManifestPodcast]
    public var episodes: [ManifestEpisode]
}
// ManifestTrack / ManifestPlaylist / ManifestPodcast / ManifestEpisode and the
// nested ReplayGain / Clip DTOs are defined field-for-field in phase 22-5,
// exactly per sync-protocol.md section 7. The clip DTO is
// { sourceTrackId, startMs, endMs }.
```

```swift
// SyncServer / Manifest (phase 22-5). What the phone is allowed to see.
public enum SyncProfile: Sendable, Codable, Equatable {
    case everything(includePodcasts: Bool)
    case selected(playlistIds: [Int64], includePodcasts: Bool)
}
```

## The generation / change model

`generation` is a monotonically increasing integer the phone polls via
`/v1/ping` to decide whether to re-sync. It **must** bump on:

- any library edit that changes a track in the profile (add, remove, tag edit,
  rating/loved change, ReplayGain, artwork, lyrics),
- any playlist change that affects the profile (membership, smart-list results,
  ordering, rename),
- any podcast change in the profile (new downloaded episode, position/state),
- **and profile edits themselves** (a profile change with an unchanged library
  must still trigger phone re-sync).

Implementation (phase 22-5): a persisted counter in a new `sync_meta` table
(migration M031), bumped by a `LibraryChangeObserver` that watches GRDB
`ValueObservation` over the tracks/playlists/podcast-state regions plus the
profile store, **debounced 5 s** so a burst of edits bumps the counter once.
`serverId` is a stable UUID minted once and stored in `sync_meta`.

## Data model additions (migration M031)

One numbered migration, `M031_PhoneSync.swift` (next free number: highest
registered is `M030`; verify the top of
`Modules/Persistence/Sources/Persistence/Migrations/Migrator.swift` and use the
next integer). Three tables:

```sql
CREATE TABLE trusted_devices (
    fingerprint  TEXT PRIMARY KEY,       -- lowercase hex SHA-256 of client cert DER
    cert_der     BLOB NOT NULL,          -- pinned client certificate
    device_name  TEXT NOT NULL,
    paired_at    REAL NOT NULL
);

CREATE TABLE sync_meta (
    id           INTEGER PRIMARY KEY CHECK (id = 1),  -- singleton row
    server_id    TEXT NOT NULL,          -- stable UUID, minted once
    generation   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sync_profile (
    id           INTEGER PRIMARY KEY CHECK (id = 1),  -- singleton row
    profile_json BLOB NOT NULL           -- encoded SyncProfile
);
```

Rationale for putting trust and profile in Persistence (GRDB) rather than a JSON
file in Application Support: consistency with the rest of the app, transactional
integrity with the generation bump, and one `ValueObservation` source for the
change observer. The server's private key and cert stay in the **Keychain**, not
here; `trusted_devices` holds only the phone's public cert.

## Cross-repo contract and fixtures checklist (applies to every slice)

- The wire behaviour is `sync-protocol.md`. If a slice needs to change wire
  behaviour, stop: edit `sync-protocol.md` first (in both repos), bump
  `protocolVersion`, then implement. Additive JSON fields do not need a version
  bump; both sides must ignore unknown fields.
- Shared fixtures are copied byte-identical, never re-authored per repo (see the
  fixtures table above).
- After editing `Modules/SyncServer/Package.swift`, the UI/`SyncServer`
  manifests, or `project.yml`, run `make generate`.
- Per the standards: 80% line coverage per module (Swift Testing, `import
  Testing`), **no network in tests** (loopback `NWListener` on `127.0.0.1` driven
  by a `URLSession` configured to trust the test cert, or `URLProtocol` stubs),
  fixtures checked in under `Modules/SyncServer/Tests/SyncServerTests/Fixtures/`.
- Run `make format && make lint && make build && make test-sync-server` before
  each commit. Conventional Commits, scope = module: `feat(sync): ...`,
  `feat(persistence): ...`, `feat(ui): ...`.

## Localization note (carry into the UI slice)

All settings and pairing-sheet chrome (labels, buttons, the six-digit code
caption, device-list column headers, confirmation copy, accessibility labels,
errors) routes through `L10n` in the `UI` catalog, and `make pseudolocale` runs
after adding keys (see `docs/design-spec/localization.md` and the `UI` module
CLAUDE.md). **Device names are user/phone content**, rendered verbatim, not
localized. New user-facing surfaces belong in the `UI` module where the catalog
and the `no_bare_user_facing_literal` guard cover them; do not add user-facing
literals to `App/`.

## Concurrency and logging (carry into every slice)

- `SyncServer` is an `actor`; all connection handling runs off the MainActor. A
  test asserts handlers run on the server's executor, not `main`, so serving
  10 GB to a phone leaves the UI responsive.
- Swift 6 strict concurrency, `Task.checkCancellation()` in every read/stream
  loop, security-scoped access always balanced (test the balance under early
  client disconnect).
- One `SyncServerError: Error, Sendable` enum carrying context (URL, underlying
  error, reason). `AppLogger` category `sync`; standard `op.start` /
  `op.end` (`ms`) / `op.failed` (`error`) pattern. Never log cert bytes, nonces,
  proofs, or the pairing code; add any sensitive keys to
  `Observability.sensitiveKeys`.

## Glossary

- **Manifest**: the single snapshot JSON describing the sync set
  (`GET /v1/manifest`), built from one `db.read`.
- **Generation**: monotonic integer the phone polls to decide whether to
  re-sync.
- **Fingerprint**: lowercase hex SHA-256 of a certificate's DER encoding; the
  whole trust decision after pairing.
- **Pairing mode**: a 120 s window (`pm=1` in TXT) during which the server
  accepts an unknown client cert to run the ceremony.
- **Sync profile**: the Mac-owned description of what a phone may see (everything
  or selected playlists; podcasts on/off).
- **Clip**: a CUE virtual track; carries `sourceTrackId/startMs/endMs` and has no
  file of its own (its bytes belong to the source track).
- **Trusted device**: a paired phone, identified by its pinned client-cert
  fingerprint in `trusted_devices`.

## Handoff

When all of Phase 22 lands:

- `SyncServer` is the home for any future LAN sync work. Any later "Phase 18"
  remote-control server reuses none of its trust store but may share extracted
  Bonjour/TLS/HTTP primitives (flagged, not pre-factored).
- The `sync_meta.generation` counter is the durable signal the phone diffs
  against; future sync features (selective playlist sync UI, size budgeting) hang
  off the `SyncProfile` model and the change observer.
- Cross-repo integration is proven by the shared fixtures (pairing vectors,
  `manifest-small.json`) plus a documented manual end-to-end run recorded in both
  repos' PRs (phase 22-9), consumed by the Android phases 02 and 03.
