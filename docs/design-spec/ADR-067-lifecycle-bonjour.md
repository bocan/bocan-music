# ADR-067: SyncServer Lifecycle + Bonjour + App Wiring

> Depends on: `ADR-060-phone-sync.md`, and every SyncServer slice ADR-062 through
> ADR-066 (this ties them into one lifecycle-managed actor). Touches **App**.
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 1 (discovery) and 3
> (TLS/listener).

## Goal

Assemble the `SyncServer` actor that owns the `NWListener` (TLS from
`ServerIdentity` + the trusted/pairing-mode verify block), advertises
`_bocansync._tcp` over Bonjour with the correct TXT record, flips pairing mode,
survives sleep/wake, and is started/stopped from the app based on the Phone Sync
enable toggle. Wire it into `App/BocanApp.swift`'s bootstrap fan-out. After this
slice, a paired phone can complete ping -> manifest -> file end to end on a real
network.

## Outcome shape

```
Modules/SyncServer/Sources/SyncServer/
  SyncServer.swift              // the top-level actor: lifecycle, listener, routing glue
  Transport/BonjourAdvertiser.swift  // TXT record + service registration via the listener
  SyncServerConfig.swift        // port (ephemeral), service type, protocol version
App/
  BocanApp.swift                // construct + start/stop in buildGraph; sleep/wake hooks
  AppGraph                      // add `let syncServer: SyncServer`
  (a SyncServerEnableStore or UserDefault for the toggle, read by Settings in ADR-068)
Modules/SyncServer/Tests/SyncServerTests/
  SyncServerLifecycleTests.swift
  BonjourAdvertiserTests.swift
```

## The `SyncServer` actor

```swift
public actor SyncServer {
    public init(identity: ServerIdentity,
                trusted: TrustedDevices,
                pairing: PairingCoordinator,
                manifest: ManifestBuilder,
                fileServing: FileServing,
                meta: SyncMetaRepository,
                serverName: @Sendable () -> String,   // Host.current().localizedName, injected from App
                config: SyncServerConfig = .default)

    public func start() async throws   // bind listener, begin advertising
    public func stop() async           // withdraw advertising, cancel connections, close listener
    public var isRunning: Bool { get }
    public func reAdvertise() async     // after wake
    // Pairing pass-throughs the UI drives (via App):
    public func armPairing() async
    public func cancelPairing() async
}
```

Responsibilities:

- Build `NWListener` on an **ephemeral port** (`.any`) with the TLS options from
  ADR-063 (`TLSOptions.make(identity:trust:pairingMode:)`), reading the actual
  bound port after `start` for the Bonjour registration.
- Bind each accepted `NWConnection` to an `HttpConnection` + `ConnectionContext`
  and hand requests to the `Router` (endpoints registered by ADR-063/ADR-064/ADR-065/ADR-066).
- Own the pairing-mode flag source of truth via `PairingCoordinator`; when
  pairing mode changes, update the Bonjour TXT `pm` field (subscribe to the
  coordinator's pairing-mode publisher from ADR-064).
- Keep an in-memory trusted-fingerprint snapshot fresh (from `TrustedDevices`,
  ADR-062) for the verify block.
- Bounded concurrency: cap simultaneous connections (e.g. a small semaphore) so a
  misbehaving client cannot exhaust file descriptors; excess connections wait or
  are closed with `503 busy`.

## Bonjour advertising (`sync-protocol.md` section 1)

Advertise via the **listener's `service`** so advertising and listening share one
lifecycle (they cannot drift):

- Service type: `_bocansync._tcp.`
- Service name: the Mac's computer name (`Host.current().localizedName`);
  identity comes from the cert, never the name.
- Port: the ephemeral bound port.
- TXT record:
  - `v` = `1`
  - `fp` = the server cert fingerprint (lowercase hex SHA-256, 64 chars, from
    `ServerIdentity`)
  - `pm` = `1` while in pairing mode, else `0`

Set the TXT via `NWTXTRecord` on `NWListener.service` before `start()`, and
update `pm` live as pairing mode toggles (re-set the service or use the listener
service-update path). This is a **separate** service from any future ADR-034
`_bocan-remote._tcp.` and a separate listener/identity/port.

### `pm` hygiene

`pm` must be `0` whenever the server is not actively in a pairing window. It flips
to `1` on `armPairing()` and back to `0` on success/timeout/lockout/cancel/error
(the coordinator guarantees the flag; the advertiser must reflect it promptly).
Never leave a Mac advertising `pm=1` at rest.

## Enable toggle + app wiring

- **Enable state**: a persisted boolean (default **off**), e.g. a
  `UserDefaults`-backed `syncServerEnabled` (or a small store) that Settings
  (ADR-068) writes and the App reads. Off by default: the listener does not bind and
  nothing is advertised until the user opts in.
- **Construction**: in `App/BocanApp.swift`, inside
  `BocanApp.buildGraph(database:appDelegate:)` (the bootstrap fan-out where
  `SubsonicService`, `PodcastService`, etc. are built), construct the
  `SyncServer` and its collaborators from the shared `Database` and repositories,
  store it as `let syncServer` on the flat `AppGraph`, and start it from a
  `Task {}` **only if** the enable toggle is on (mirroring how
  `feedRefreshScheduler.start()` / scrobble `.start()` are kicked off there).
  `serverName` is injected as a `@Sendable () -> String` returning
  `Host.current().localizedName` so `SyncServer` does not import AppKit.
- **Toggle handling**: turning the toggle on calls `syncServer.start()`; off
  calls `syncServer.stop()` (withdraws Bonjour + closes the listener within ~1 s).
  Wire this from the Settings view model in ADR-068.
- **Sleep/wake**: hook the existing `NSWorkspace` observers installed by
  `installSleepWakeAndDeviceChangeObservers(...)` in `BocanApp` (these live in the
  App target because lower modules do not import AppKit). On `willSleep`, the
  listener may drop; on `didWake`, call `syncServer.reAdvertise()` so the service
  reappears. Re-advertising after wake is an acceptance criterion.
- **Termination**: on `applicationWillTerminate` (via the existing termination
  observer), `stop()` the server so the Bonjour service is withdrawn cleanly.

## Entitlements (already present, do not re-add)

`Resources/Bocan.entitlements` already declares
`com.apple.security.network.server` **and** `com.apple.security.network.client`
(alongside `app-sandbox`, `files.user-selected.read-write`, and
`files.bookmarks.app-scope`). Sandbox + hardened runtime are enabled globally in
`project.yml` (`ENABLE_APP_SANDBOX: YES`, `ENABLE_HARDENED_RUNTIME: YES`). So,
contrary to the Android-side brief, **no new entitlement is needed for this
ADR**. Confirm the file still lists `network.server`; do not add per-feature
entitlement files (there is a single app-level entitlements file). There is no
`keychain-access-groups` entry (CI strips it on unsigned builds) and the login
keychain the identity uses (ADR-062) does not require one.

## Tests

- **`SyncServerLifecycleTests`**: `start()` binds a listener and reports a nonzero
  port; a `URLSession` (test-cert-trusting) can `GET /v1/ping`; `stop()` closes it
  (subsequent connect fails); start/stop is idempotent; `reAdvertise()` after a
  simulated wake makes the service resolvable again.
- **`BonjourAdvertiserTests`**: after `start`, an `NWBrowser` for
  `_bocansync._tcp` finds the service within a few seconds with TXT `v=1`, the
  right `fp`, and `pm=0`; after `armPairing()`, `pm` flips to `1`; after
  cancel/timeout, back to `0`.
- **Off-by-default**: with the enable toggle off, `buildGraph` does not start the
  server and nothing is advertised.
- **Responsiveness**: streaming a large file (reuse ADR-066) while the test's main
  actor does work shows the handlers run off-main (assert executor).

Bonjour tests are inherently timing-sensitive; use generous polling with a
bounded deadline (the CI-flakiness note in the repo: avoid tight real-time waits;
poll until found or a max deadline).

## Context7 lookups

- use context7: Network.framework NWListener service NWTXTRecord Bonjour
  _tcp advertise update TXT record NWBrowser discovery
- use context7: NSWorkspace willSleepNotification didWakeNotification observer
  macOS

## Acceptance criteria

- [x] Enabling Phone Sync starts the listener, binds an ephemeral port, and
      advertises `_bocansync._tcp` with TXT `v/fp/pm`; disabling withdraws it
      within ~1 s.
- [x] Off by default: fresh launch advertises nothing until the user opts in.
- [x] `pm` is `1` only during an active pairing window and `0` at rest.
- [x] The service reappears after sleep/wake (`reAdvertise`).
- [x] The server is a separate listener/identity/port from any ADR-034 service;
      no shared trust store.
- [x] No new entitlement added (`network.server` already present); sandbox +
      hardened runtime intact.
- [x] `make format && make lint && make build && make test-sync-server` green;
      `make generate` clean; coverage floor met.

## Handoff

ADR-068 builds the Settings pane + pairing sheet that drives
`start()`/`stop()`, `armPairing()`, and implements the `PairingUIBridge`
(`showCode`, `requestConfirmation`). ADR-069 runs the real-device end-to-end
against the Android client and sweeps the acceptance boxes.
