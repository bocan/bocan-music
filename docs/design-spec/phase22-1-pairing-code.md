# Phase 22-1: PairingCode + Golden Vectors

> Depends on: `phase22-0-overview.md` (read it first). No other prerequisites:
> this slice is pure, test-first, and has zero dependency on the rest of the
> module or on the Android client.
>
> Binding docs: `docs/design-spec/_standards.md`,
> `../bocan-music-android/docs/design-spec/sync-protocol.md` section 4.

## Why this is first

The six-digit pairing code and the confirm proof are the two pieces of math both
platforms must compute **byte-identically** or pairing silently fails in a way
that is miserable to debug across two repos and two languages. So we lock it
first, in isolation, against the golden vectors the Android side already
generated. If the Mac reproduces all five vectors, the pairing math is provably
compatible before either side opens a socket. Nothing else in Phase 22 should be
built until this is green.

This slice creates the `SyncServer` module scaffold (Package only, no listener
yet) so there is somewhere for `PairingCode` and its tests to live.

## Outcome shape

```
Modules/SyncServer/
  Package.swift                          // depends on Observability only (for now)
  Sources/SyncServer/
    Pairing/PairingCode.swift            // the frozen math, pure, Sendable
    SyncServerError.swift                // module error enum (first case here)
  Tests/SyncServerTests/
    PairingCodeTests.swift               // golden-vector suite
    Fixtures/pairing-vectors.json        // copied byte-identical from Android
```

`Package.swift` names the product `SyncServer`, target `SyncServer`, test target
`SyncServerTests`, and declares `Fixtures/` as a test resource
(`.copy("Fixtures")`) so `swift test` and `make test-sync-server` pick it up as a
bundle resource. Depend only on `Observability` at this point; later slices add
`Persistence`, `Library`, and `Podcasts`.

## The contract (sync-protocol.md section 4, restated)

Given the two certificate fingerprints (lowercase hex SHA-256 of each cert's DER)
and the two 32-byte nonces:

```
fpLo  = min(fpMac, fpPhone)              // lexicographic on the hex strings
fpHi  = max(fpMac, fpPhone)
key   = noncePhone || nonceMac           // raw bytes, phone nonce first
msg   = "bocan-pair-v1" || fpLo || fpHi  // ASCII bytes of the literal and hex strings
code  = decimal( first 8 bytes of HMAC-SHA256(key, msg) as unsigned big-endian ) mod 1_000_000
```

Rendered as six digits, zero-padded (`String(format: "%06d", code)`), displayed
grouped as `123 456` but compared as the six-digit string.

The confirm proof (section 4 step 5):

```
proof = HMAC-SHA256( key = code-as-ASCII-bytes, msg = sessionId-as-ASCII-bytes )
```

base64-encoded (standard, with padding, matching the fixture).

### Exact byte rules (the places this goes wrong)

- **Fingerprint case**: lowercase hex, 64 chars. `min`/`max` are lexicographic on
  those ASCII hex strings, not on raw bytes. Compare with the default `String`
  ordering; the strings are equal length so lexicographic == byte order.
- **Nonce concatenation order**: HMAC key is `noncePhone` first, then `nonceMac`.
  Nonces in the vectors are base64; decode to raw bytes before concatenating.
- **`msg` literal**: the ASCII bytes of `bocan-pair-v1` immediately followed by
  the ASCII bytes of `fpLo` then `fpHi`, no separators.
- **Big-endian, unsigned**: take the first 8 bytes of the 32-byte HMAC output,
  interpret as a big-endian `UInt64`, then `% 1_000_000`. Do not use the whole
  digest; do not use little-endian.
- **Proof key is the code string**, i.e. the ASCII bytes of the six-digit
  zero-padded string (e.g. `"704898"`), not the integer, not the ungrouped vs
  grouped question (no space).

## API

```swift
public enum PairingCode {
    /// The six-digit verification code, zero-padded, e.g. "704898".
    public static func code(
        fpMac: String,
        fpPhone: String,
        noncePhone: Data,
        nonceMac: Data
    ) -> String

    /// The base64 confirm proof for a session id.
    public static func proof(
        code: String,
        sessionId: String
    ) -> String
}
```

Implemented with CryptoKit `HMAC<SHA256>`; no third-party crypto. Pure, no I/O,
`Sendable` by being a caseless enum of static funcs. Both functions are total (no
throws); malformed input is a programming error caught by tests, not a runtime
branch.

## The golden vectors

`../bocan-music-android/core/sync/src/test/resources/fixtures/pairing-vectors.json`
holds five vectors, each with `fpMac`, `fpPhone`, `noncePhoneBase64`,
`nonceMacBase64`, `expectedCode`, `sessionId`, `expectedProofBase64`. Copy the
file **byte-identical** into
`Modules/SyncServer/Tests/SyncServerTests/Fixtures/pairing-vectors.json`. Do not
reformat it; a byte-for-byte copy keeps the two repos honest.

> Coordination note: at time of writing these vectors are committed on the Mac
> side by this slice but were still in the Android working tree. Confirm they are
> committed in `../bocan-music-android` (they are deterministic output of
> `scripts/gen-pairing-vectors.py`) so both repos pin the same tracked artifact.
> If they are regenerated for any reason, regenerate and re-commit in both repos
> in the same change.

## Tests (`PairingCodeTests.swift`)

Swift Testing. Load the fixture from the test bundle
(`Bundle.module.url(forResource:withExtension:)`), decode to `[Vector]`, and:

1. **Code parity** (parameterized over the five vectors): decode the base64
   nonces, call `PairingCode.code(...)`, `#expect` it equals `expectedCode`.
2. **Proof parity** (parameterized): call `PairingCode.proof(code:sessionId:)`
   with the vector's `expectedCode` and `sessionId`, `#expect` the base64 equals
   `expectedProofBase64`.
3. **Symmetry**: swapping `fpMac` and `fpPhone` yields the same code (the `min`/
   `max` normalization makes the ceremony order-independent).
4. **Determinism**: two calls with identical inputs return identical output.
5. **Mismatch sensitivity**: flipping one hex nibble of a fingerprint, or one
   byte of a nonce, changes the code (guards against a degenerate implementation
   that ignores an input).

No network, no I/O beyond the bundled fixture. This is the fastest suite in the
module and the canary for cross-repo drift.

## Wiring in this slice

- Create `Modules/SyncServer/Package.swift`; add `Modules/SyncServer` to the
  `packages:` block in `project.yml`; run `make generate`.
- Add a `test-sync-server` target to the `Makefile` mirroring `test-podcasts`,
  and a coverage floor entry in the `coverage-all` machinery.
- `SyncServerError` gets its first case here (e.g. `.pairing(reason:)`); it grows
  in later slices.

Defer the `_standards.md` / `CLAUDE.md` DAG-table edits to phase 22-2, where the
module first takes a Persistence dependency and the edges become real.

## Context7 lookups

- use context7: CryptoKit HMAC SHA256 authenticationCode SymmetricKey Data

## Acceptance criteria

- [x] `PairingCode.code` reproduces all five `expectedCode` values byte-identical.
- [x] `PairingCode.proof` reproduces all five `expectedProofBase64` values.
- [x] Symmetry, determinism, and mismatch-sensitivity tests pass.
- [x] `pairing-vectors.json` is byte-identical to the Android copy and committed
      in both repos.
- [x] `Modules/SyncServer` builds; `make test-sync-server` is green; module
      coverage floor met (this slice alone should be ~100% of `PairingCode`).
- [x] `make format && make lint && make build` green.

## Handoff

Phases 22-2 (identity computes the `fpMac` this consumes) and 22-4 (the ceremony
calls `PairingCode.code`/`.proof`) depend on this exact math. The golden-vector
suite is the regression gate for any future touch of section 4.
