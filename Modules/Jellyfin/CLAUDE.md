# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Jellyfin` module (ADR-097). For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Talking to Jellyfin servers. It is a **sibling** of `Subsonic`: it mirrors that module's shape and never imports it, and `Subsonic` never imports `Jellyfin`. A Jellyfin file that looks like its Subsonic twin is the intended result.

- `JellyfinService.swift` (+ `JellyfinService+Endpoints.swift`) is the actor: a client pool, browse, lists, playlists, search, favourites, play reports and media URLs. It talks to `JellyfinClientProtocol` only.
- `JellyfinSDKClient.swift` (+ `+Browse`), `JellyfinMapping.swift` and `JellyfinStreamURL.swift` are the **only** files that import the official `jellyfin-sdk-swift` (`JellyfinAPI`) and its HTTP layer `Get`. `Scripts/audit-jellyfin-sdk-imports.py` keeps it so from `make lint`. The SDK's DTOs are mapped to this module's own `Jellyfin*` models (`Models/`) at the edge.
- `JellyfinAuth.swift` is everything before a server has a token: probe, password sign-in, and Quick Connect (the polling loop lives here, not in the SDK client, so its timing is tested).
- `JellyfinServerStore.swift` persists rows (through `JellyfinServerRepository` in `Persistence`) and keeps the **access token** in the login Keychain, service `io.cloudcauldron.bocan.jellyfin`, account `<serverID>`. The password is used once and never stored.
- `JellyfinConnectionMonitor.swift`, `JellyfinAnnotations.swift` and `JellyfinCoverArtProvider.swift` mirror their Subsonic twins.

## Things easy to get wrong

- **Never log, store or put in an error a stream or image URL.** They carry the access token as `ApiKey`. Log the item id instead. `JellyfinError` messages are URL-free by construction; keep it so.
- **The ping is `GET /Users/Me`, not `/System/Ping`**, because only an authenticated call notices a revoked token. See `docs/GOTCHAS.md`.
- **Ids are opaque strings.** Do not parse, re-case or reformat them. Ticks are 100 ns: `RunTimeTicks / 10_000_000` is seconds, and positions go the other way as `Int64`.
- **A model field the server did not send is `nil`.** A mapper never invents a value.
- **Do not name a type `Server`, `Song` or `Album`.** Everything here starts with `Jellyfin`.
- **The bitrate cap applies only when a format is chosen.** With the original format the static stream is sent as it is (`JellyfinStreamURL`).
- **Login Keychain only, no `kSecAttrAccessible*`**, and read again before treating "not found" as final (`settledKeychainRead`). Tests give the store its own Keychain service name so they never touch a real server's item.
- **Tests must not hit the network.** `StubURLProtocol` drives the real SDK client without a socket; `StubJellyfinClient` and `StubAuthClient` script the seam. The checked-in fixtures are shaped like Jellyfin's responses but were written by hand. Real captures hold someone's own library, so they are not checked in: make them with `Scripts/capture-jellyfin-fixtures.py` and run `JELLYFIN_CAPTURE_DIR=<dir> swift test --filter Captured` to push them through the real SDK client and the mappers. Fold any new shape the captures show into the hand-written fixtures.

## Testing

Run `make test-jellyfin` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Jellyfin`, or `make test-coverage`), run `make test-jellyfin` last so the full module suite is the final gate before the commit.
