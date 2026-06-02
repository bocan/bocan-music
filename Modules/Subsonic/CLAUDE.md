# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Subsonic` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Talking to Subsonic-compatible servers. The public seam is the `SubsonicService` actor, which wraps the external **`SwiftSonic`** client.

- `SubsonicService.swift` (+ `SubsonicService+CapabilityProbe.swift`) is the actor: browse, search, stream URLs, star/rate, and capability detection. `SwiftSonicReexport.swift` re-exports the external package's types so callers do not depend on it directly.
- `SubsonicServerStore.swift` persists server configs and stores credentials in the **Keychain**. `Models/` holds `SubsonicServer`, `SubsonicError`, `SubsonicConnectionStatus`. `SubsonicConnectionMonitor.swift` tracks per-server reachability; `SubsonicAnnotations.swift` and `SubsonicCoverArtProvider.swift` handle star/rating writes and artwork.

## Things easy to get wrong

- **The `UI` and `Scrobble` modules must not import `Subsonic`.** They declare protocols (sidebar listing, connection observing, capability-change observing, scrobble delivery, metadata caching, stream resolving) and the **App layer** provides the concrete adapters. If a higher module needs something here, add a protocol there and an adapter in `App/`, not a direct dependency.
- **Capability snapshots are persisted per server** and `loadCapabilities` is only auto-invoked from the bootstrap fan-out in `BocanApp.swift` and the Settings "Test Connection" path. Sidebar rows are gated on the persisted JSON, so a newly exposed capability will not appear until something kicks a refresh or the cache ages past `freshnessInterval` (24 h).
- **Credentials live in the login (file-based) Keychain, not the data-protection Keychain.** Do not add `kSecUseDataProtectionKeychain` here: on macOS the data-protection Keychain is scoped to the app's code-signing identity and did not survive local rebuilds (writes succeeded but read back as `errSecItemNotFound`, blanking the password every launch). Do not set `kSecAttrAccessible` either; those accessibility classes are undefined on the file Keychain and caused intermittent read failures. Reads, writes, deletes, and `migrateOrphans` must all target the same (file) store.
- **Tests must not hit the network.** Stub the transport; capability/annotation tests assert behaviour against a mock, not a live server.

## Testing

Run `make test-subsonic` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Subsonic`, or `make test-coverage`), run `make test-subsonic` last so the full module suite is the final gate before the commit.
