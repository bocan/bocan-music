# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Acoustics` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Acoustic fingerprinting and the metadata lookup that follows from it.

- `Fingerprinter.swift` computes a Chromaprint fingerprint by invoking the bundled **`fpcalc`** binary as a subprocess (`Process`). `FingerprintResult.swift` is its output.
- `AcoustIDClient.swift` maps a fingerprint to MusicBrainz IDs; `MusicBrainzClient.swift` / `MBRecording.swift` fetch recording details. Both go through the `HTTPClient` protocol (`HTTPClient.swift`) so tests can inject a mock, and both rate-limit via `RateLimiter.swift`.

## Things easy to get wrong

- **`fpcalc` is run as an external `Process`.** Validate the input before handing it over: assert `url.isFileURL` and reject paths containing a NUL byte (a NUL silently truncates the argument). The bundled `fpcalc` and its FFmpeg dylibs are produced by `make bundle-fpcalc` (see the root `CLAUDE.md`), not checked into git.
- **The AcoustID API key goes in the POST body, never the URL**, so it does not leak into logs or referers. Keep that when adding requests.
- **MusicBrainz is strictly rate-limited (about 1 req/s).** Route every outbound call through `RateLimiter`; honour `Task` cancellation so a cancelled lookup never fires the request.
- **Tests must not hit the network.** Use the `MockHTTPClient`; fixtures (sample fingerprints, JSON responses) are checked in.

## Testing

Run `make test-acoustics` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Acoustics`, or `make test-coverage`), run `make test-acoustics` last so the full module suite is the final gate before the commit.
