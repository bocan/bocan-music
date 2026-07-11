# Phase 22-4: Pairing Ceremony (server side)

> Depends on: `phase22-0-overview.md`, `phase22-1-pairing-code.md` (the math),
> `phase22-2-identity-trust.md` (`ServerIdentity` fingerprint + `TrustedDevices`),
> `phase22-3-http-listener.md` (`Router`, `ConnectionContext`, TLS verify block).
>
> Binding docs: `_standards.md`, `sync-protocol.md` section 4.

## Goal

The server side of the pairing ceremony: a `PairingSession` state machine, the
`POST /v1/pair/start` and `POST /v1/pair/confirm` handlers, pairing-mode
entry/exit with strict `pm` TXT hygiene, nonce generation, code/proof
verification via `PairingCode`, rate limiting, and the two UI-facing hooks (show
the code; ask for the final human confirmation). The actual settings sheet is
phase 22-8; this slice exposes the seam it drives.

Pairing is the security boundary (the TXT `fp` pin is unauthenticated; the code
match is the proof). Get the state machine, the rate limits, and the pairing-mode
lifecycle exactly right.

## Outcome shape

```
Modules/SyncServer/Sources/SyncServer/
  Pairing/PairingSession.swift     // one in-flight ceremony: nonces, code, deadline, failures
  Pairing/PairingCoordinator.swift // actor: at most one active session, rate limits, pm toggle
  Http/Handlers/PairingHandler.swift // /v1/pair/start, /v1/pair/confirm
  Pairing/PairingUIBridge.swift    // protocol: showCode(_:), requestConfirmation(device:) -> Bool
Modules/SyncServer/Tests/SyncServerTests/
  PairingCeremonyTests.swift       // loopback happy path + failure modes
  PairingCoordinatorTests.swift    // state machine in isolation
```

## State machine (`PairingSession` + `PairingCoordinator`)

There is **at most one** active pairing session at a time (a single Mac being
paired to a single phone in a 120 s window). `PairingCoordinator` is an actor
owning the optional current session and the pairing-mode flag.

States:

```
idle
  -> (user clicks "Pair a phone")            -> armed        (pm=1, 120s deadline, no session yet)
armed + POST /v1/pair/start (valid)          -> awaitingCode (nonces exchanged, code computed)
awaitingCode + POST /v1/pair/confirm (proof ok, human Trust) -> paired (persist, pm=0, idle)
any state + deadline elapsed                 -> idle (pm=0)
awaitingCode + 3 bad proofs                  -> idle (pm=0)
```

`PairingSession` holds: `sessionId` (UUID), `noncePhone`, `nonceMac`,
`fpPhone` (from the connection's recorded client cert), the computed `code`, the
`deadline`, and a `failedProofs` counter. It is created on `start` and discarded
on success, timeout, or lockout.

`PairingCoordinator` API:

```swift
public actor PairingCoordinator {
    public init(identity: ServerIdentity, trusted: TrustedDevices,
                ui: PairingUIBridge, now: @Sendable () -> Date = Date.init)

    /// User clicked "Pair a phone". Enters pairing mode for 120 s.
    public func arm() async
    /// Whether pm should be advertised as 1 right now.
    public var isPairingMode: Bool { get }
    /// Handler entry points (called by PairingHandler):
    public func start(request: PairStart, peerFingerprint: String,
                      peerCertDER: Data) async throws -> PairStartResponse
    public func confirm(request: PairConfirm) async throws -> PairConfirmResponse
    /// Force-exit (settings toggle off, app teardown).
    public func cancel() async
}
```

The `now` injection makes the 120 s deadline and rate-limit windows testable
without real waits (the standards flag real-time-wait tests as flaky; do not
`Task.sleep` in tests).

## Endpoints

### `POST /v1/pair/start`

Allowed only pre-pairing and only when `isPairingMode` is true (otherwise
`403 notPaired` or `409`/`pairingExpired` per section 5). Body:

```json
{ "protocolVersion": 1, "deviceName": "Chris's Pixel", "noncePhone": "<32 bytes base64>" }
```

Handler:

1. Validate `protocolVersion == 1` (else the version error from section 10).
2. Read the **peer certificate from the `ConnectionContext`** (recorded by the
   verify block in 22-3), never from the JSON, and compute `fpPhone`.
3. Generate `nonceMac` (32 random bytes, `SystemRandomNumberGenerator` /
   `SecRandomCopyBytes`) and a `sessionId` UUID.
4. Compute `code = PairingCode.code(fpMac:, fpPhone:, noncePhone:, nonceMac:)`
   using `ServerIdentity`'s fingerprint for `fpMac`.
5. Store the session in the coordinator; call `ui.showCode(code)` on the
   MainActor.
6. Respond `200`:

```json
{ "protocolVersion": 1, "serverName": "Chris's MacBook", "nonceMac": "<32 bytes base64>", "sessionId": "<uuid>" }
```

`serverName` is `Host.current().localizedName` (computed in App and injected, or
read via a small seam so `SyncServer` does not import AppKit).

### `POST /v1/pair/confirm`

Body:

```json
{ "sessionId": "<uuid>", "proof": "<base64 HMAC-SHA256(key=code ASCII, msg=sessionId ASCII)>" }
```

Handler:

1. Look up the session by `sessionId` on the same connection; mismatch or no
   session -> `410`/`pairingExpired` (or `404` per section 5 mapping).
2. Recompute the expected proof with `PairingCode.proof(code:sessionId:)` and
   compare **constant-time** (`Data` equality is fine here since both are
   fixed-length HMAC outputs; still avoid early-out string compares on the
   base64). On mismatch: increment `failedProofs`; if it reaches 3, discard the
   session and exit pairing mode; return `403`/`badProof` (or `429`/`rateLimited`
   on the lockout).
3. On match: call `ui.requestConfirmation(device: deviceName, fpTail:
   last8HexOf(fpPhone))` on the MainActor and await the human decision. This is
   the mandatory final human click; it returns `Bool`.
   - If the user declines: discard the session, exit pairing mode, return
     `403`/`badProof`-style refusal (the phone treats a non-2xx confirm as
     "not paired").
   - If the user accepts: `trusted.trust(TrustedDevice(fingerprint: fpPhone,
     certDER: peerCertDER, deviceName:, pairedAt: now))`, exit pairing mode,
     respond `200`:

```json
{ "status": "paired", "serverId": "<uuid, stable per Mac>" }
```

`serverId` comes from `sync_meta` (phase 22-5 owns minting/storing it; until then
inject it). After a successful pair, the phone's next connection presents the now
trusted client cert and the verify block admits it outside pairing mode.

## `pm` TXT hygiene (a named gotcha)

`isPairingMode` must revert to `false` on **every** exit path: success, timeout,
3-strike lockout, user-declines-confirmation, `cancel()`, and any thrown error in
the handlers. A Mac stuck advertising `pm=1` invites drive-by pairing attempts
(harmless due to the code check + human confirm, but noisy and wrong). Phase 22-7
reads `isPairingMode` to set the TXT `pm` field and must re-read it whenever the
coordinator transitions; model this as the coordinator publishing pairing-mode
changes (an `AsyncStream<Bool>` or a callback) so the Bonjour advertiser updates
the TXT record promptly.

## Rate limits and lifetime

- **120 s deadline** from `arm()`. On expiry: session discarded, `pm=0`. A new
  attempt needs a fresh `arm()` (a fresh "Pair a phone" click), which regenerates
  nonces.
- **3 failed proofs** kills the session and exits pairing mode.
- The deadline is enforced by comparing `now()` at each handler entry, plus a
  single scheduled `Task` that fires at the deadline to flip `pm=0` even if no
  further request arrives. Cancel that task on early exit.
- Only one session at a time; a second `start` while a session is live either
  replaces it (fresh phone tapped) or is rejected. Prefer: a `start` from a
  different peer fingerprint while `awaitingCode` replaces the session (the user
  may have tapped the wrong Mac first); document the choice and test it.

## `PairingUIBridge`

```swift
public protocol PairingUIBridge: Sendable {
    /// Show the six-digit code on the Mac (pairing sheet). Called on MainActor.
    func showCode(_ code: String) async
    /// The mandatory final confirmation. Returns true if the user clicks Trust.
    func requestConfirmation(deviceName: String, fingerprintTail: String) async -> Bool
    /// Pairing ended (success/timeout/cancel): dismiss the sheet.
    func pairingEnded(result: PairingResult) async
}
```

Implemented by the settings pairing sheet in phase 22-8; a test double drives the
ceremony tests here. Keep this the **only** UI seam the ceremony needs.

## Tests

- **`PairingCoordinatorTests`** (no sockets, injected `now`): arm -> start
  produces a code matching `PairingCode`; confirm with the right proof and a
  Trust-returning bridge -> `paired` + device inserted + `pm=0`; wrong proof x3
  -> lockout + `pm=0`; deadline elapsed -> session gone + `pm=0`; user declines
  confirmation -> not trusted + `pm=0`; `start` when not armed -> rejected.
- **`PairingCeremonyTests`** (loopback TLS from 22-3): full happy path over a real
  handshake, phone cert recorded by the verify block, code computed on both sides
  (the test acts as the phone using `PairingCode`), confirm succeeds, and a
  **subsequent** connection with the same client cert is admitted outside pairing
  mode (proves trust persisted). A revoke (phase 22-2) then blocks the next
  connection.
- Every exit path asserts `isPairingMode == false` afterward (the `pm` hygiene
  invariant), and asserts the code/nonces/proofs never appear in logs.

## Context7 lookups

- use context7: CryptoKit HMAC SHA256 constant time comparison SecRandomCopyBytes
  32 bytes nonce

## Acceptance criteria

- [x] Happy-path ceremony completes over loopback TLS; the paired phone is
      admitted on its next connection; `manifest`/file endpoints become reachable.
- [x] Wrong proof x3 -> lockout (`rateLimited`/`badProof`), session discarded,
      `pm=0`.
- [x] 120 s timeout discards the session and reverts `pm=0` (tested with injected
      clock, no real sleep).
- [x] The mandatory human confirmation is required; declining does not trust the
      device.
- [x] `pm` reverts to `0` on every exit path; pairing-mode changes are published
      for the advertiser.
- [x] Peer fingerprint is taken from the TLS layer, never the JSON.
- [x] No code/nonce/proof/cert bytes in logs; `make ... test-sync-server` green;
      coverage floor met.

## Handoff

Phase 22-7 reads `isPairingMode` for the TXT `pm` field and calls `arm()` /
`cancel()` from the settings toggle + "Pair a phone" button. Phase 22-8
implements `PairingUIBridge` as the real sheet. Phases 22-5/22-6 endpoints are
now reachable by a paired phone.
