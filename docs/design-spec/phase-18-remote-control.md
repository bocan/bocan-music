# Phase 18: Remote Control (Bocan Player side)

> Prerequisites: Phases 0–16 complete. `QueuePlayer` exposes the full `Transport`
> protocol. Persistence layer is stable. Settings UI exists.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Turn Bòcan into a controllable player that companion apps (iOS, iPadOS, Android)
can discover on the local network, pair with using a PIN, and then use to browse
the library and control playback. All communication is encrypted. Bòcan exposes a
management UI where the user can see, and revoke, every bonded remote.

This document covers the **Bocan (macOS) side only**: the embedded HTTP/WebSocket
server, the Bonjour advertisement, the pairing ceremony, the REST + WebSocket API,
and the settings UI. The companion app designs are separate documents.

## Non-goals

- Internet / relay / cloud connectivity. LAN only.
- Uploading or syncing music files to/from the remote.
- The companion apps themselves (this spec only defines what the server exposes).
- Controlling other apps from Bòcan (the remote is a *controller of* Bòcan, not a
  universal remote).
- Volume control of the remote device's own hardware speaker.
- Push notifications / background wake when Bòcan is not running.

## Outcome shape

```
Modules/Remote/
├── Package.swift
├── Sources/Remote/
│   ├── RemoteServer.swift             # Actor, owns NWListener, routes requests
│   ├── BonjourAdvertiser.swift        # Registers / withdraws _bocan-remote._tcp.
│   ├── TLSIdentity.swift              # Generates + persists self-signed TLS cert
│   ├── Pairing/
│   │   ├── PairingSession.swift       # In-flight pairing state machine
│   │   └── PairingStore.swift         # Persists bonded remotes via RemoteClientRepo
│   ├── Handlers/
│   │   ├── RequestRouter.swift        # Parses HTTP method + path → handler
│   │   ├── PairingHandler.swift       # POST /v1/pair/start, /v1/pair/verify
│   │   ├── LibraryHandler.swift       # GET /v1/library/*
│   │   ├── PlaybackHandler.swift      # POST /v1/playback/* (commands)
│   │   └── StateHandler.swift         # GET /v1/playback/state
│   ├── Events/
│   │   ├── EventBus.swift             # Actor, fan-out playback events
│   │   └── WebSocketSession.swift     # One per connected remote
│   └── Errors.swift
└── Tests/RemoteTests/
    ├── PairingSessionTests.swift
    ├── LibraryHandlerTests.swift
    ├── PlaybackHandlerTests.swift
    └── EventBusTests.swift

Modules/Persistence/Sources/Persistence/
├── Migrations/
│   └── M0xx_RemoteClients.swift       # New migration
└── Repositories/
    └── RemoteClientRepository.swift   # CRUD for bonded remotes

Modules/UI/Sources/UI/Settings/
└── RemoteClientsView.swift            # Management UI

App/BocanApp.swift                     # Wires RemoteServer into the app lifecycle
```

---

## Security model

### TLS transport

Bòcan generates a **self-signed X.509 certificate** (RSA-2048 or P-256 ECDSA)
the first time the remote server starts. The certificate and its private key are
stored in the macOS Keychain under the app's access group (`io.cloudcauldron.bocan`).
The certificate has a 10-year validity; `TLSIdentity` re-generates it if it has
fewer than 30 days remaining.

The certificate's **SHA-256 fingerprint** is included in the Bonjour TXT record
(key `fp`). A companion app connecting for the first time must verify the
fingerprint shown in the TXT record matches the certificate presented over TLS. On
subsequent connections the app pins to the stored fingerprint; a fingerprint change
(e.g. certificate regeneration) triggers a re-pairing prompt.

### Pairing ceremony

The goal is to bind a specific remote device to this Bòcan instance without any
pre-shared secret. The PIN adds human confirmation so a rogue app on the same LAN
cannot silently bond.

```
Remote app                           Bòcan
────────────────────────────────────────────────────────────────
1. Discover via Bonjour + verify TLS fingerprint
2. POST /v1/pair/start
   { deviceName, deviceID, platform }  ─────────────────────────→
                                       3. Persist pending session
                                          Show 6-digit PIN in UI
                                       ←── { sessionToken (temp) }
4. User reads PIN from Bòcan screen
   POST /v1/pair/verify
   { sessionToken (temp), pin }  ──────────────────────────────→
                                       5. Validate PIN (constant-time)
                                          Generate 256-bit bearer token
                                          Persist bonded client record
                                          Dismiss PIN UI
                                       ←── { bearerToken, serverName }
6. Store bearerToken + cert fingerprint
   All future requests: Authorization: Bearer <token>
```

- The PIN is a random 6-digit decimal string, shown for 120 seconds. After
  expiry the pending session is discarded and the caller receives `410 Gone`.
- PIN comparison uses constant-time equality (`timingsafe_bcmp` equivalent) to
  prevent timing attacks.
- The temporary session token is a 128-bit random value (URL-safe base64). It
  identifies the pairing session only; it is NOT usable as an API credential.
- The bearer token is a 256-bit random value (URL-safe base64), stored in
  `remote_clients.token_hash` as a `SHA-256` hash. The raw token is never stored.
- There is no upper limit on the number of bonded remotes, but each bonding
  requires a separate PIN ceremony.

### Request authentication

Every request (except `GET /v1/pair/start`) must carry:

```
Authorization: Bearer <token>
```

`RemoteServer` looks up the SHA-256 hash of the token in `remote_clients`, returns
`401 Unauthorized` if not found. A successful lookup updates `last_used_at`.

---

## Service discovery

### Bonjour service

`BonjourAdvertiser` registers an `NWListener`-backed service:

| Property | Value |
|---|---|
| Service type | `_bocan-remote._tcp.` |
| Default port | `47421` |
| TXT record `name` | The machine name (`Host.current().localizedName`) |
| TXT record `ver` | Bòcan version string (e.g. `1.2.0`) |
| TXT record `fp` | Hex-encoded SHA-256 of the TLS certificate's DER encoding |
| TXT record `api` | API version (`1`) |

The service is only advertised while the "Allow remote control" toggle is on
(default: **off**). `BonjourAdvertiser` withdraws the service immediately when the
toggle is turned off or the app is in the background for more than 60 seconds.

Bòcan listens only on `lo0` and LAN interfaces (explicitly excludes `utun*`
VPN interfaces and `bridge*`). The port is configurable in Settings within the
range 1024–65535.

---

## API reference

All endpoints are under HTTPS on the configured port. Request and response bodies
are `application/json; charset=utf-8`.

### Common response envelope

Success:
```json
{ "data": <payload> }
```

Error:
```json
{ "error": { "code": "NOT_FOUND", "message": "Album 99 not found" } }
```

Standard error codes: `UNAUTHORIZED`, `FORBIDDEN`, `NOT_FOUND`, `BAD_REQUEST`,
`RATE_LIMITED`, `INTERNAL`.

---

### Pairing

#### `POST /v1/pair/start`

No auth required.

Request:
```json
{
  "deviceID":   "stable-uuid-generated-on-first-install",
  "deviceName": "Chris's iPhone",
  "platform":   "ios"            // "ios" | "android"
}
```

Response `200`:
```json
{
  "data": {
    "sessionToken": "base64url-128-bit-random",
    "expiresIn":    120
  }
}
```

Response `409 Conflict` if a pairing for this `deviceID` already exists and is
still active (rate-limits repeated hammering).

#### `POST /v1/pair/verify`

No auth required.

Request:
```json
{
  "sessionToken": "…",
  "pin":          "123456"
}
```

Response `200`:
```json
{
  "data": {
    "bearerToken": "base64url-256-bit-random",
    "serverName":  "Chris's Mac Studio"
  }
}
```

Response `403` on wrong PIN. Response `410` on expired session.

---

### Library: Songs

#### `GET /v1/library/songs`

| Query param | Type | Default | Description |
|---|---|---|---|
| `q` | string |, | Full-text search |
| `limit` | int | 50 | Max results (1–200) |
| `offset` | int | 0 | Pagination offset |
| `sort` | string | `title` | `title` \| `artist` \| `album` \| `added_at` |

Response `200`:
```json
{
  "data": {
    "total": 1842,
    "items": [
      {
        "id":       123,
        "title":    "Through the Never",
        "artist":   "Metallica",
        "album":    "Metallica",
        "duration": 301,
        "trackNum": 7,
        "year":     1991,
        "genre":    "Metal"
      }
    ]
  }
}
```

---

### Library: Albums

#### `GET /v1/library/albums`

| Query param | Type | Default | Description |
|---|---|---|---|
| `q` | string |, | Full-text search |
| `limit` | int | 50 | Max results (1–200) |
| `offset` | int | 0 | Pagination offset |
| `artistID` | int |, | Filter to one artist |

Response items include `id`, `title`, `artist`, `year`, `trackCount`,
`artURL` (relative path, see below).

#### `GET /v1/library/albums/{id}/tracks`

Returns the track list for an album. Items have the same shape as song items above,
plus `discNum`.

---

### Library: Artists

#### `GET /v1/library/artists`

| Query param | Type | Default |
|---|---|---|
| `q` | string |, |
| `limit` | int | 50 |
| `offset` | int | 0 |

Items: `id`, `name`, `albumCount`, `trackCount`.

#### `GET /v1/library/artists/{id}/albums`

Returns albums for one artist. Same shape as `/v1/library/albums` items.

---

### Library: Genres

#### `GET /v1/library/genres`

No pagination (genres are expected to be few). Returns:
```json
{
  "data": [
    { "name": "Metal",     "trackCount": 312 },
    { "name": "Classical", "trackCount": 88 }
  ]
}
```

#### `GET /v1/library/genres/{name}/tracks`

Supports `limit`, `offset`, `sort`. Same item shape as `/v1/library/songs`.
`name` is URL-encoded.

---

### Library: Playlists

#### `GET /v1/library/playlists`

Items: `id`, `name`, `trackCount`, `isSmartPlaylist`, `updatedAt`.

#### `GET /v1/library/playlists/{id}/tracks`

Supports `limit`, `offset`. Items same as `/v1/library/songs`.

---

### Cover art

#### `GET /v1/art/{albumID}`

Returns the album's cover art as a JPEG (max 512×512, server-side resize), with
appropriate `Cache-Control: max-age=86400`. Returns `404` if no art exists.

Remote apps should use this URL in `artURL` fields from library responses. The
app-level cache is the caller's responsibility.

---

### Playback: State

#### `GET /v1/playback/state`

Returns current playback state without subscribing to the event stream:
```json
{
  "data": {
    "status":   "playing",
    "track": {
      "id":       123,
      "title":    "Through the Never",
      "artist":   "Metallica",
      "album":    "Metallica",
      "duration": 301,
      "artURL":   "/v1/art/45"
    },
    "position":   142.3,
    "volume":     0.8,
    "shuffle":    true,
    "repeat":     "off",
    "queueSize":  18,
    "queueIndex": 6
  }
}
```

`status`: `"playing"` | `"paused"` | `"loading"` | `"ended"` | `"idle"`

---

### Playback: Commands

All commands return `204 No Content` on success.

#### `POST /v1/playback/play`

Replaces the queue and starts playback.

```json
{
  "trackIDs": [123, 124, 125],
  "startAt":  0,
  "shuffle":  false
}
```

#### `POST /v1/playback/pause`

Pauses (no body).

#### `POST /v1/playback/resume`

Resumes from pause (no body).

#### `POST /v1/playback/next`

Advances to next track (no body).

#### `POST /v1/playback/previous`

Goes to previous track or restarts current if > 3 s in (no body).

#### `POST /v1/playback/seek`

```json
{ "position": 95.0 }
```

#### `POST /v1/playback/volume`

```json
{ "level": 0.65 }
```

`level` is `0.0`–`1.0`. Sets the application-level output volume (not system
volume).

#### `POST /v1/playback/shuffle`

```json
{ "enabled": true }
```

#### `POST /v1/playback/repeat`

```json
{ "mode": "all" }
```

`mode`: `"off"` | `"one"` | `"all"`

---

### Real-time events: WebSocket

#### `GET /v1/events` (WebSocket upgrade)

After the HTTP handshake the connection is upgraded to a WebSocket. The bearer
token is sent in the `Authorization` header of the upgrade request. The server
sends JSON frames; the client never sends frames (read-only push channel).

**Frame envelope:**
```json
{ "event": "<event_type>", "data": { … } }
```

| Event | When | Data fields |
|---|---|---|
| `state_changed` | Play/pause/loading/ended | `status`, `position` |
| `track_changed` | New track starts | Full track object (same as `/v1/playback/state`) |
| `position_tick` | Every 5 s while playing | `position` (seconds, float) |
| `queue_changed` | Queue replaced or item added/removed | `queueSize`, `queueIndex` |
| `volume_changed` | Volume adjusted | `level` |
| `shuffle_changed` | Shuffle toggled | `enabled` |
| `repeat_changed` | Repeat mode changed | `mode` |

`position_tick` is sent every 5 seconds while playing so the remote app can keep
its scrubber in sync without polling. Silence during pause.

On disconnect and reconnect the client should call `GET /v1/playback/state` to
re-sync before resubscribing.

---

## Persistence

### New migration: `remote_clients`

Add `Modules/Persistence/Sources/Persistence/Migrations/M0xx_RemoteClients.swift`:

```swift
// Schema:
// remote_clients
//   id           TEXT    PRIMARY KEY    -- stable UUID sent by remote app
//   name         TEXT    NOT NULL       -- e.g. "Chris's iPhone"
//   platform     TEXT    NOT NULL       -- "ios" | "android"
//   token_hash   BLOB    NOT NULL       -- SHA-256 of bearer token (32 bytes)
//   cert_fp      BLOB    NOT NULL       -- TLS cert fingerprint at time of pairing
//   created_at   INTEGER NOT NULL       -- Unix timestamp
//   last_used_at INTEGER NOT NULL       -- Unix timestamp, updated on each request
```

### `RemoteClientRepository`

```swift
public actor RemoteClientRepository {
    public func insert(_ client: RemoteClient) async throws
    public func fetchAll() async throws -> [RemoteClient]
    public func fetchByTokenHash(_ hash: Data) async throws -> RemoteClient?
    public func updateLastUsed(id: String) async throws
    public func delete(id: String) async throws
}
```

`RemoteClient` is a `Codable`, `Sendable` value type mirroring the schema above.

---

## Implementation plan

### Step 1: Persistence layer

1. Add `M0xx_RemoteClients.swift` migration following the existing numbered
   migration pattern in `Modules/Persistence/`.
2. Add `RemoteClient.swift` (value type + GRDB `TableRecord`).
3. Add `RemoteClientRepository.swift`.
4. Write repository tests (insert, fetch-by-token-hash, delete, last-used update).

### Step 2: TLS identity

5. Add `Modules/Remote/Package.swift` depending on `Observability` and
   `Persistence`.
6. Implement `TLSIdentity.swift`:
   - On first call, generate a P-256 self-signed certificate using `Security`
     framework (`SecKeyCreateRandomKey` + `SecCertificateCreateWithData`).
   - Store private key in Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
   - Store cert in Keychain as well; derive fingerprint via `SecCertificateCopyData`
     + SHA-256.
   - Expose `secIdentity: SecIdentity` and `fingerprintHex: String`.
7. Write a test that calls `TLSIdentity.shared` twice and verifies the same
   fingerprint is returned (key persistence).

### Step 3: Core server

8. Implement `RemoteServer.swift` actor:
   - `NWListener` on the configured port with TLS using `NWProtocolTLS.Options`
     loaded from `TLSIdentity`.
   - Dispatch each accepted `NWConnection` to `RequestRouter`.
   - Expose `start() async throws` / `stop() async`.
   - Expose `var port: UInt16` (actual bound port after start).
9. Implement `RequestRouter.swift`:
   - Parse HTTP/1.1 request line + headers from raw `NWConnection` data.
   - Authenticate bearer token (skip for pair endpoints).
   - Dispatch to the appropriate handler.
   - Write helpers: `respond(status:body:)`, `respondNoContent()`, `respondError(_:)`.
10. Write server integration test: start server on port 0, make a `URLSession`
    request (with self-signed cert trust), verify `401` without token.

### Step 4: Pairing

11. Implement `PairingSession.swift` value type: holds `deviceID`, `deviceName`,
    `platform`, `pin`, `sessionToken`, `expiresAt`.
12. Implement `PairingHandler.swift`:
    - `POST /v1/pair/start` → generate PIN + session token, store session in
      an in-memory `[String: PairingSession]` dictionary (keyed by `sessionToken`),
      trigger `showPIN(_:)` callback (injected closure, called on `@MainActor`).
    - `POST /v1/pair/verify` → look up session, constant-time compare PIN,
      generate bearer token, call `RemoteClientRepository.insert`, call
      `dismissPIN()` callback, return token.
    - Expire sessions older than 120 s in a lightweight `Task.sleep` loop.
13. Write pairing flow tests using the server integration harness.

### Step 5: Library handlers

14. Implement `LibraryHandler.swift`, injected with `TrackRepository`,
    `AlbumRepository`, `ArtistRepository`, `PlaylistRepository`.
15. All list endpoints support `limit` (clamped to 200), `offset`, and `q`.
16. `GET /v1/art/{albumID}` reads the cached cover-art JPEG from the same
    location the main app uses; resize to 512×512 using `CoreImage` if larger.
17. Write handler unit tests with an in-memory database seeded with fixture data.

### Step 6: Playback handlers

18. Implement `PlaybackHandler.swift` injected with `QueuePlayer`.
19. `POST /v1/playback/play` calls `QueuePlayer.play(items:shuffle:)`.
20. Implement all other command endpoints by delegating to the appropriate
    `QueuePlayer` methods.
21. Write handler tests using a mock `Transport` conformance.

### Step 7: State + WebSocket events

22. Implement `EventBus.swift` actor:
    - Holds a `[UUID: AsyncStream<ServerEvent>.Continuation]` for connected clients.
    - Subscribes to `QueuePlayer.state` and `QueuePlayer.currentTrackChanges`.
    - Fan-outs events to all continuations.
    - Exposes `subscribe() -> AsyncStream<ServerEvent>` and `unsubscribe(id:)`.
23. Implement `WebSocketSession.swift`:
    - Handles the WebSocket upgrade over the existing `NWConnection`.
    - Consumes `EventBus.subscribe()` in a `Task`, serialises events to JSON,
      writes frames via `NWConnection.send`.
    - Sends `position_tick` events via a 5-second timer task while status is
      `.playing`.
    - Cleans up on connection close.
24. Implement `StateHandler.swift` for `GET /v1/playback/state`.
25. Write event bus tests: verify fan-out, verify disconnected clients are cleaned up.

### Step 8: Bonjour advertisement

26. Implement `BonjourAdvertiser.swift`:
    - Uses `NWListener` service registration (set `service` on the listener
      before calling `start()`).
    - Encodes TXT record fields as a `Data`-dictionary via
      `NWTXTRecord`.
    - Responds to `start(port:)` / `stop()`.
27. Integrate with `RemoteServer`: advertise after the listener is bound,
    withdraw before the listener stops.
28. Write a test that starts the advertiser and verifies the service appears via
    `NWBrowser` within 5 seconds.

### Step 9: App wiring

29. In `BocanApp.swift`, construct `RemoteServer` after `QueuePlayer` is ready.
30. Inject `RemoteServer` as an environment object so the Settings view can toggle
    it on/off and read the current port + active connection count.
31. Add a `"Allow remote control"` toggle to Settings (default off). When toggled
    on, call `RemoteServer.start()`; off calls `stop()`.
32. Show the configured port number and a "Pair a remote" button (triggers the
    pairing PIN flow manually without waiting for a remote to initiate).

### Step 10: Management UI

33. Implement `RemoteClientsView.swift` in `Modules/UI/`:
    - `List` of bonded remotes from `RemoteClientRepository.fetchAll()`.
    - Each row: device name, platform icon (SF Symbol `iphone` / `ipad.gen2` /
      `app.connected.to.app.below.fill` for Android), created date,
      last-used date.
    - Swipe-to-delete / context-menu `Delete` calls `RemoteClientRepository.delete(id:)`.
    - Empty state: "No paired remotes. Enable remote control in Settings to pair."
34. Accessible: each row has `accessibilityLabel` combining name + platform +
    last-used date.

### Step 11: Hardening

35. Rate-limit pairing: after 5 failed PIN attempts from the same `sessionToken`,
    discard the session and return `429 Too Many Requests`.
36. Ensure `NWListener` accepts at most 8 concurrent connections; reject with
    `503 Service Unavailable` beyond that.
37. Add a log category `remote` to `AppLogger` (`Observability` module).
38. Audit all `RemoteServer` code paths for information leakage in error responses
    (error messages must not reveal internal paths or DB structure).

### Step 12: Tests & CI gate

39. Unit tests for every handler, `PairingSession` expiry, `EventBus` fan-out,
    and `TLSIdentity` persistence.
40. Integration test: full pairing ceremony over localhost using `URLSession` with
    a custom `URLSessionDelegate` that trusts the test self-signed cert.
41. Integration test: WebSocket `position_tick` arrives within 8 seconds of
    playback starting (use a fake `QueuePlayer` that emits `.playing` on demand).
42. `make test` must pass. Add `Modules/Remote` to the test matrix in `ci.yml`.

---

## Definitions & contracts

### `RemoteClient`

```swift
public struct RemoteClient: Sendable, Identifiable {
    public let id: String          // UUID from the remote app
    public let name: String        // Human-readable device name
    public let platform: String    // "ios" | "android"
    public let tokenHash: Data     // SHA-256(bearerToken), 32 bytes
    public let certFingerprint: Data  // SHA-256(DER cert), 32 bytes
    public let createdAt: Date
    public var lastUsedAt: Date
}
```

### `ServerEvent`

```swift
public enum ServerEvent: Sendable {
    case stateChanged(status: String, position: Double)
    case trackChanged(track: RemoteTrack)
    case positionTick(position: Double)
    case queueChanged(size: Int, index: Int)
    case volumeChanged(level: Double)
    case shuffleChanged(enabled: Bool)
    case repeatChanged(mode: String)
}
```

`RemoteTrack` is a `Codable`, `Sendable` DTO mirroring the track JSON shape.

### Threat model notes

- **TLS + cert pinning** protects against passive eavesdropping and active MITM
  on the network.
- **PIN ceremony** prevents silent bonding by a malicious app on the same LAN.
- **Bearer token stored as hash** means a DB read does not yield a usable token.
- **No token refresh**. If a token is compromised the user revokes it in the
  management UI. Tokens do not expire automatically (remote app reconnects
  without needing to re-pair).
- **LAN-only listener** (no `0.0.0.0` on `utun*` / VPN interfaces) limits the
  attack surface to devices on the same physical network.
- This system is not designed to be exposed to the public internet. There is no
  defence-in-depth for an internet-facing deployment.

---

## Acceptance criteria

- [ ] `BonjourAdvertiser` registers `_bocan-remote._tcp.` and is discoverable by
      a real iOS device running `NWBrowser` on the same Wi-Fi network.
- [ ] Full PIN pairing ceremony completes over localhost in the integration test.
- [ ] `GET /v1/library/songs` returns correct paginated results from a seeded
      in-memory database.
- [ ] `POST /v1/playback/play` causes `QueuePlayer` to start playing (mock
      verified).
- [ ] `WebSocketSession` delivers a `track_changed` event to the client when
      `QueuePlayer.currentTrackChanges` emits.
- [ ] `RemoteClientsView` shows bonded remotes and allows deletion; deletion
      removes the row and invalidates the token (subsequent API call returns `401`).
- [ ] 5 wrong-PIN attempts expire the session and return `429`.
- [ ] Toggling "Allow remote control" off stops the listener and withdraws the
      Bonjour service within 1 second.
- [ ] All new Swift code compiles with `-strict-concurrency=complete` without
      suppressions.
- [ ] `make lint && make test-coverage` is green.
