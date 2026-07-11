# Phase 22-2: ServerIdentity (Keychain) + TrustedDevices (Persistence)

> Depends on: `phase22-0-overview.md`, `phase22-1-pairing-code.md`.
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 2 and 3.

## Goal

The two "who am I / who do I trust" pieces:

1. `ServerIdentity`: a P-256 key + self-signed cert created once and stored in the
   login Keychain, exposing a `SecIdentity` for the TLS listener and a lowercase
   hex SHA-256 fingerprint for the TXT record and pairing math.
2. `TrustedDevices`: the persisted set of paired phones (pinned client-cert
   fingerprint + cert DER + name + date), stored in GRDB via migration M031, with
   an in-memory snapshot the TLS verify block can consult cheaply, plus
   revocation.

This slice also performs the DAG bookkeeping now that `SyncServer` takes a
`Persistence` dependency (the module edges become real here).

## Outcome shape

```
Modules/SyncServer/Sources/SyncServer/
  Identity/ServerIdentity.swift    // actor: create-or-load key+cert, fingerprint, SecIdentity
  Identity/SelfSignedCert.swift    // P-256 self-signed X.509 DER builder
  Trust/TrustedDevices.swift       // actor over TrustedDeviceRepository + in-memory snapshot
Modules/Persistence/Sources/Persistence/
  Migrations/M031_PhoneSync.swift  // trusted_devices, sync_meta, sync_profile
  Records/TrustedDevice.swift      // GRDB record
  Records/SyncMeta.swift           // singleton: server_id, generation
  Records/SyncProfileRecord.swift  // singleton: profile_json
  Repositories/TrustedDeviceRepository.swift
  Repositories/SyncMetaRepository.swift
Modules/SyncServer/Tests/SyncServerTests/
  ServerIdentityTests.swift
  TrustedDevicesTests.swift
Modules/Persistence/Tests/PersistenceTests/
  M031MigrationTests.swift
  TrustedDeviceRepositoryTests.swift
```

## ServerIdentity

`public actor ServerIdentity`. On first use it creates, and thereafter loads, a
stable identity:

- **Key**: P-256 (`SecKeyCreateRandomKey` with
  `kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom`, `kSecAttrKeySizeInBits:
  256`), or CryptoKit `P256.Signing.PrivateKey` bridged to `SecKey` via its
  `x963Representation`. Prefer the `Security`-framework path so the key can live
  in the Keychain as a `SecKey`.
- **Certificate**: a self-signed X.509 DER, CN `bocan-mac-<8 random hex>`,
  validity 25 years, signed with the P-256 key (ECDSA-with-SHA256). Built in
  `SelfSignedCert.swift`. There is no third-party X.509 library in the repo;
  hand-build the minimal DER (TBSCertificate + signature) or use the smallest
  viable approach the Context7 lookup surfaces. Keep it to exactly the fields the
  pin needs: version, serial, signature alg, issuer==subject (CN), validity,
  subjectPublicKeyInfo, signature. No extensions required (the pin is the trust
  decision, not the chain).
- **Fingerprint**: `SHA256(certDER)` rendered lowercase hex, 64 chars. Exposed as
  `ServerFingerprint`.
- **SecIdentity**: assembled from the `SecKey` + `SecCertificate`
  (`SecIdentityCreateWithCertificate` or by storing the identity and reading it
  back). Exposed for `TLSOptions` (phase 22-3).

### Keychain storage

Mirror the existing generic-password pattern, and use the **login (file-based)
Keychain, not the data-protection Keychain**. The Subsonic store deliberately
avoids `kSecUseDataProtectionKeychain` / `kSecAttrAccessible` because the
data-protection keychain did not survive local rebuilds (read back
`errSecItemNotFound`); see `Modules/Subsonic/Sources/Subsonic/SubsonicServerStore.swift`
(the `writeItem` update-then-add flow around the keychain helpers) and
`Modules/Subsonic/CLAUDE.md`. Follow the same convention:

- Service string: `io.cloudcauldron.bocan.sync` (new, distinct from
  `.subsonic` / `.scrobble`, and distinct from any future Phase 18 remote
  identity).
- Store the cert (DER) and the private key. `SecIdentity` items
  (`kSecClassIdentity`) are new ground for this repo (no existing helper stores
  `kSecClassIdentity`/`kSecClassKey`); the cleanest approach is to store the
  `SecKey` (`kSecClassKey`) and the certificate (`kSecClassCertificate`)
  separately, then reconstruct the `SecIdentity` at load with
  `SecIdentityCreateWithCertificate(nil, cert, &identity)`. Use update-then-add
  semantics (mirror `writeItem`).
- Idempotency: a second `ServerIdentity` construction returns the same key, cert,
  and fingerprint (the stability test below).

> Signing caveat: there is no `keychain-access-groups` entitlement (CI strips it
> on unsigned builds; see the Makefile note about stripping it). Storing a
> `SecKey` in the login keychain does not require an access group. If a future
> change moves this to the data-protection keychain, note that it forces real
> signing (Team 4P7SKNWGR6 + a provisioning profile) and the app can no longer
> build ad-hoc; keep the login keychain unless there is a concrete reason not to.

### API

```swift
public actor ServerIdentity {
    public init(keychainService: String = "io.cloudcauldron.bocan.sync")
    /// Create on first call, load thereafter. Stable across launches.
    public func load() async throws -> Loaded
    public struct Loaded: Sendable {
        public let secIdentity: SecIdentity
        public let certDER: Data
        public let fingerprint: ServerFingerprint   // lowercase hex SHA-256
        public let commonName: String               // bocan-mac-<8hex>
    }
}
```

## TrustedDevices + migration M031

### Migration

`M031_PhoneSync.swift`, registered at the top of
`Modules/Persistence/Sources/Persistence/Migrations/Migrator.swift` as the next
integer after `M030` (verify it is still the highest). Creates the three tables
from the overview: `trusted_devices`, `sync_meta`, `sync_profile`. Follow the
existing migration style (raw `db.create(table:)` or SQL string as the other
`M0xx` files do). `sync_meta` and `sync_profile` are singleton rows guarded by
`CHECK (id = 1)`; seed neither here (they are created lazily by the repositories,
mirroring how `podcast_episode_state` rows are created lazily).

`sync_meta` and `sync_profile` are consumed by phase 22-5 (generation, serverId,
profile). This slice creates the tables and the `TrustedDevice` machinery; it may
add the `SyncMeta`/`SyncProfileRecord` records + repositories as thin stubs now
or defer them to 22-5. Prefer adding all three tables in the one migration (a
migration is append-only once shipped) and leaving the sync_meta/profile
repositories for 22-5.

### Records + repository

`TrustedDevice` GRDB record (table `trusted_devices`, PK `fingerprint`) mirroring
the shared value type in the overview. `TrustedDeviceRepository: Sendable` over
the `Database` actor, following the existing repository pattern (`public struct`
holding `private let database: Database`, wrapping `database.read/write`):

```swift
public struct TrustedDeviceRepository: Sendable {
    public init(database: Database)
    public func all() async throws -> [TrustedDevice]
    public func insert(_ device: TrustedDevice) async throws        // pairing confirm
    public func contains(fingerprint: String) async throws -> Bool
    public func delete(fingerprint: String) async throws            // revoke
    /// ValueObservation stream of the full set, for the in-memory snapshot.
    public func observeAll() async -> AsyncThrowingStream<[TrustedDevice], Error>
}
```

### `TrustedDevices` actor (in SyncServer)

Wraps the repository and holds an **in-memory snapshot** of the fingerprint set
so the TLS verify block (phase 22-3) does not hit the database per handshake:

```swift
public actor TrustedDevices {
    public init(repository: TrustedDeviceRepository)
    public func start() async          // seed snapshot + subscribe to observeAll
    public func isTrusted(_ fingerprint: String) -> Bool   // snapshot lookup, sync
    public func trust(_ device: TrustedDevice) async throws // insert + snapshot update
    public func revoke(fingerprint: String) async throws    // delete + snapshot update
    public func list() async throws -> [TrustedDevice]
}
```

`isTrusted` is a synchronous snapshot read so it can be handed to the verify
block as a `@Sendable (String) -> Bool` closure. The `observeAll` subscription
keeps the snapshot fresh so a revoke from the UI propagates to the snapshot, and
therefore to the next handshake, without a server restart. Respect the GRDB 7.9
`requiresWriteAccess = true` observation caveat noted on `Database.observe`.

## DAG bookkeeping (do it here)

- `Modules/SyncServer/Package.swift`: add `Persistence` (and `Observability`,
  already there) as dependencies. `Library` and `Podcasts` are added in the
  slices that first need them (22-5/22-6); do not add them speculatively.
- `_standards.md`: add the `SyncServer` row to the "Current internal-module
  dependencies" table (`SyncServer` depends on `Observability, Persistence,
  Library, Podcasts` once complete; add the full set now with a note that
  Library/Podcasts edges arrive in 22-5/22-6, or add incrementally). Add
  `SyncServer` to the `UI` row when 22-8 lands.
- `CLAUDE.md`: update the DAG diagram + module table; add the `sync` log category
  to the AppLogger list.
- `LogCategory.swift`: add the `sync` case.
- `project.yml`: (already added the package in 22-1) no change unless the target
  graph shifts; `make generate` if manifests changed.

## Tests

- **`ServerIdentityTests`**: fingerprint is 64 lowercase hex chars; two `load()`
  calls return the same fingerprint and cert DER (stability); the cert's CN
  matches `bocan-mac-<8hex>`; the `SecIdentity` yields a usable server cert in a
  loopback TLS handshake (shares the `TestIdentity` helper with 22-3). Use a test
  keychain service string and clean it up.
- **`M031MigrationTests`**: migrating from M030 creates the three tables with the
  right columns and the singleton CHECK constraints; migration is idempotent
  under the existing migration-test harness.
- **`TrustedDeviceRepositoryTests`**: insert/contains/delete round-trip on an
  in-memory `Database`; `observeAll` emits on insert and delete.
- **`TrustedDevicesTests`**: `isTrusted` reflects an inserted device after
  `start()`; a `revoke` removes it from the snapshot; the snapshot updates when
  the underlying table changes via a second repository handle (proves the
  observation wiring, mirroring the revoke-takes-effect acceptance test in 22-3).

## Context7 lookups

- use context7: Security framework SecKeyCreateRandomKey P-256 ECSECPrimeRandom
  SecCertificateCreateWithData SecIdentityCreateWithCertificate Keychain SecItemAdd
- use context7: CryptoKit P256 Signing PrivateKey x963Representation SHA256 DER
- use context7: GRDB DatabaseMigrator create table numbered migration record

## Acceptance criteria

- [x] `ServerIdentity.load()` creates once, loads thereafter; identical
      fingerprint + cert across calls; fingerprint is 64-char lowercase hex.
- [x] The identity's `SecIdentity` completes a loopback TLS handshake as the
      server (verified with the 22-3 harness).
- [x] M031 creates `trusted_devices`, `sync_meta`, `sync_profile`; migration
      tests green; no change to prior migrations.
- [x] `TrustedDevices.isTrusted` is a synchronous snapshot read; insert and
      revoke propagate to the snapshot via `observeAll`.
- [x] DAG tables in `_standards.md` / `CLAUDE.md` updated; `sync` log category
      added; `make generate` clean.
- [x] `make format && make lint && make build && make test-sync-server &&
      make test-persistence` green; coverage floors met.

## Handoff

Phase 22-3 consumes `ServerIdentity.Loaded.secIdentity` for the TLS local
identity and `TrustedDevices.isTrusted` for the verify block. Phase 22-4 calls
`TrustedDevices.trust(...)` on a successful pairing confirm. Phase 22-5 fills in
the `sync_meta` (serverId + generation) and `sync_profile` repositories over the
tables this migration created.
