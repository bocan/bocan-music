# Phase 8.5 — AcoustID Fingerprinting & MusicBrainz Auto-Tagging

> Prerequisites: Phase 8 (Metadata Editor) complete. Phase 3 TagLib bridge includes writing support.
>
> Read `phases/_standards.md` first.

## Goal

Identify tracks whose metadata is missing or incorrect by computing an acoustic fingerprint (via Chromaprint / fpcalc), submitting it to the AcoustID lookup service, resolving the result against MusicBrainz, and offering the user confirmed tag data to apply through the Phase 8 tag writer.

## Non-goals

- Auto-tagging entire libraries without user confirmation — never auto-apply.
- Discogs fingerprinting — out of scope.
- Beat-grid / BPM detection — out of scope.
- Submitting new fingerprints to AcoustID — stretch; not required for v1.

## Outcome shape

```
Modules/Acoustics/
├── Package.swift
├── Sources/Acoustics/
│   ├── Fingerprinter.swift            # Drives fpcalc (subprocess) or linked chromaprint
│   ├── AcoustIDClient.swift           # HTTPS lookup against api.acoustid.org/v2/lookup
│   ├── MusicBrainzClient.swift        # HTTPS recording/release lookups (MusicBrainz JSON API v2)
│   ├── RateLimiter.swift              # Sliding-window throttle: 3 req/s AcoustID, 1 req/s MB
│   ├── FingerprintResult.swift        # Parsed AcoustID response
│   ├── MBRecording.swift              # MusicBrainz recording model
│   └── Errors.swift
└── Tests/AcousticsTests/
    ├── FingerprinterTests.swift
    ├── AcoustIDClientTests.swift
    ├── MusicBrainzClientTests.swift
    └── Fixtures/
        ├── acoustid_response_single.json
        ├── acoustid_response_multi.json
        └── mb_recording_response.json

Modules/Library/Sources/Library/Fingerprint/
├── FingerprintService.swift           # Orchestrator: fingerprint → AcoustID → MB → present
├── FingerprintStore.swift             # Persists fingerprint + AcoustID ID in DB
└── FingerprintQueue.swift             # Serial async queue; respects rate limits

Modules/UI/Sources/UI/Fingerprint/
├── IdentifyTrackSheet.swift           # Sheet triggered by context menu
├── CandidatePickerView.swift          # Multi-candidate result list with confidence scores
└── ViewModels/
    └── IdentifyTrackViewModel.swift
```

## Schema

Add via a new migration (M005, after Phase 9's M004):

```sql
ALTER TABLE tracks ADD COLUMN acoustid_fingerprint TEXT;
ALTER TABLE tracks ADD COLUMN acoustid_id TEXT;
ALTER TABLE tracks ADD COLUMN musicbrainz_recording_id TEXT;
```

Indices:

```sql
CREATE INDEX IF NOT EXISTS idx_tracks_acoustid_id ON tracks(acoustid_id);
CREATE INDEX IF NOT EXISTS idx_tracks_mb_recording_id ON tracks(musicbrainz_recording_id);
```

## Implementation plan

### Fingerprinting

1. **`Fingerprinter`** — wraps `fpcalc` (Chromaprint CLI tool shipped as a bundled binary under `Resources/fpcalc`):
   - Runs as a `Process` with arguments `-json -length 120 <filepath>`.
   - Decodes the JSON output: `{ "fingerprint": "...", "duration": N }`.
   - Returns a `(fingerprint: String, duration: Int)` tuple.
   - Requires the security-scoped URL for the file; resolves via the track's bookmark before launching.
   - If `fpcalc` is absent or returns a non-zero exit code, throws `AcousticsError.fpcalcFailed`.

   Alternatively, evaluate linking `libchromaprint` directly via a binary xcframework vendored under `Resources/`. Use whichever approach produces a smaller binary and simpler code path. Document the decision in source.

2. **`AcoustIDClient`** — calls `https://api.acoustid.org/v2/lookup`:
   - Parameters: `client` (API key from `Secrets.xcconfig`), `meta=recordings+releases+tracks`, `fingerprint`, `duration`.
   - Response model: array of `{ id, score, recordings: [{ id, title, artists, releases }] }`.
   - API key stored in `Secrets.xcconfig` (git-ignored); injected at build time via an `Info.plist` key.
   - Rate limit: 3 requests/second. Enforced by `RateLimiter`.
   - All network requests go through a protocol-based `HTTPClient` so tests can inject a stub.

3. **`MusicBrainzClient`** — queries `https://musicbrainz.org/ws/2/recording/<mbid>?inc=releases+artists&fmt=json`:
   - Parses release list to extract: title, artist credit, album title, album artist, track number, disc number, year, label, genre (from tags).
   - `User-Agent` header: `Bòcan/<version> ( <support URL> )` — required by MusicBrainz policy.
   - Rate limit: 1 request/second. Enforced by the same `RateLimiter` instance (separate bucket).

4. **`FingerprintService`** — orchestrates the flow:
   1. Fingerprint the file via `Fingerprinter`.
   2. Look up AcoustID → get candidates sorted by score.
   3. For each candidate recording above 0.5 confidence, look up MusicBrainz to enrich the metadata.
   4. Return an array of `IdentificationCandidate` sorted by score descending.
   5. Persist the fingerprint and AcoustID ID to the DB regardless of whether the user applies the match.

5. **`FingerprintQueue`** — serialises concurrent identify requests to respect rate limits. Limits concurrency to 1 for MusicBrainz (strict 1 req/s) and up to 3 for AcoustID.

### UI

6. **`IdentifyTrackSheet`** — modal sheet, opens via:
   - Context menu: "Identify Track…" on a single selected track.
   - Toolbar button when exactly one track is selected.
   - `⌘⌥I` shortcut.

   States:
   - **Computing fingerprint**: indeterminate spinner, "Computing fingerprint…"
   - **Looking up**: spinner, "Looking up…"
   - **Results**: `CandidatePickerView`
   - **No match**: "No match found. Try editing tags manually." with a link to open the Phase 8 tag editor.
   - **Error**: error message + Retry button.

7. **`CandidatePickerView`** — displays candidates as a list:
   - Each row: track title, artist, album, year, confidence bar (e.g. 94%).
   - Tapping a row expands it to show additional release info (label, cat. no., track/disc number, barcode).
   - "Apply" button (primary) → calls `MetadataEditService.apply(_:to:)` via Phase 8's tag writer. Shows a brief success toast.
   - "Skip" button (secondary) → dismisses without writing.
   - Multiple candidates may appear; user picks one or none.

## Definitions & contracts

### `IdentificationCandidate`

```swift
public struct IdentificationCandidate: Sendable, Identifiable {
    public let id: String                  // AcoustID ID
    public let score: Double               // 0...1
    public let mbRecordingID: String?
    public let title: String
    public let artist: String
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let genre: String?
    public let label: String?
}
```

### `AcousticsError`

```swift
public enum AcousticsError: Error, Sendable {
    case fpcalcFailed(exitCode: Int32, stderr: String)
    case networkError(underlying: Error)
    case rateLimitExceeded
    case noResults
    case invalidResponse(reason: String)
    case tagWritebackFailed(underlying: Error)
}
```

## Context7 lookups

- `use context7 Foundation Process async output capture Swift 6`
- `use context7 URLSession async throws data request Swift 6`
- `use context7 Swift actor rate limiter token bucket`
- `use context7 JSONDecoder keyDecodingStrategy camelCase Swift`
- `use context7 SwiftUI sheet async task loading state`

## Dependencies

| Dependency | How | Version |
|---|---|---|
| `fpcalc` (Chromaprint CLI) | Bundled binary in `Resources/fpcalc` for arm64 + x86_64 (fat binary). Build script in `scripts/build-fpcalc.sh` using Homebrew `chromaprint`. | ≥ 1.5 |
| No new SPM packages | AcoustID + MusicBrainz are plain REST/JSON; no SDK needed. | — |

The bundled `fpcalc` binary must be code-signed with the app's certificate. Add it to the app's Copy Files build phase and add a hardened-runtime entitlement for `com.apple.security.cs.allow-unsigned-executable-memory` only if chromaprint requires it (it should not on arm64/x86_64 — verify).

## Test plan

### Fingerprinter

- Mock `Process`; verify correct arguments are passed (`-json -length 120 <path>`).
- A non-zero exit code raises `AcousticsError.fpcalcFailed`.
- JSON parse: fixture with known fingerprint string round-trips cleanly.

### AcoustIDClient

- `URLProtocol` stub returns `acoustid_response_single.json`; verify `IdentificationCandidate` count == 1 and score == fixture value.
- Stub returns `acoustid_response_multi.json`; verify candidates are sorted by score descending.
- HTTP 429 → `AcousticsError.rateLimitExceeded`.
- Network error → `AcousticsError.networkError`.

### MusicBrainzClient

- Stub returns `mb_recording_response.json`; verify `MBRecording` fields match fixture.
- `User-Agent` header is present and well-formed.

### RateLimiter

- Issue 4 requests at once on the 3-req/s bucket; the 4th is delayed by ≥ 333 ms.
- Issue 2 requests at once on the 1-req/s bucket; the 2nd is delayed by ≥ 1 s.

### FingerprintService (integration)

- End-to-end with all HTTP stubs: fingerprint → AcoustID → MB → `IdentificationCandidate` array with correct fields.
- Fingerprint and AcoustID ID written to DB after lookup regardless of user action.

### UI (snapshot)

- Sheet in each state: computing, looking up, results (1 candidate), results (3 candidates), no match, error.
- Light + dark, normal + large text.

## Acceptance criteria

- [ ] Right-click a track → "Identify Track…" opens the sheet.
- [ ] Fingerprint computed in < 5 s on a 3-minute track on M-series Mac.
- [ ] AcoustID + MusicBrainz lookups complete; at least one candidate shown for a well-known track (verified manually with a fixture).
- [ ] Confidence scores displayed accurately (match AcoustID response).
- [ ] "Apply" writes metadata to the file via Phase 8's `MetadataEditService`.
- [ ] Rate limits are respected: verified via test timing assertions.
- [ ] Fingerprint and AcoustID ID persisted to DB regardless of user action.
- [ ] No network calls in unit tests (all stubbed).
- [ ] 80%+ coverage on `Modules/Acoustics`.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Binary signing**: `fpcalc` must be code-signed and copied into the app bundle. Unsigned helper binaries will be rejected by macOS Gatekeeper. Use `codesign --deep` during the build, and test on a clean account without Developer ID bypass.
- **Hardened runtime + subprocess**: launching a subprocess from a sandboxed app requires the `com.apple.security.temporary-exception.files.absolute-path.read-write` entitlement for the file's path, or use the bookmark's security scope before launching `fpcalc`. Prefer passing the resolved path under security scope.
- **MusicBrainz rate limit**: 1 req/s is strict. If you exceed it you get HTTP 503 and a potential IP ban. The `RateLimiter` must be a single shared instance across all lookup paths.
- **MusicBrainz `User-Agent`**: the policy mandates a valid contact URL. Use `https://github.com/your-repo/bocan` or a support page. A missing or generic `User-Agent` will result in 403 responses.
- **AcoustID API key**: never commit it. Store in `Secrets.xcconfig` (added to `.gitignore`), inject via `Info.plist`, read at runtime from `Bundle.main.infoDictionary`. Provide a `Secrets.xcconfig.template` in the repo.
- **Low-confidence matches**: scores below 0.5 are often wrong. Show them in the UI with a visual warning; never auto-apply anything.
- **Cancelled tasks**: if the sheet is dismissed mid-lookup, cancel the in-flight `FingerprintService` task. The partially computed fingerprint may still be written to the DB (acceptable) but no network request should continue running after cancellation.
- **Multiple releases per recording**: a MusicBrainz recording often has many releases (original, remaster, various territories). Surface the release list with enough info (year, label, barcode) for the user to pick the right one.

## Handoff

Phase 9 (EQ/Effects) and Phase 13 (Last.fm scrobbling) expect:

- `tracks.musicbrainz_recording_id` is populated for any track the user has identified; scrobbling can use it for MusicBrainz-linked scrobbles.
- `FingerprintService` is available as an injectable dependency for future batch-identification tooling.
