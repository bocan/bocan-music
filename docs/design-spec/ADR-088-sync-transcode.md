# ADR-088: Sync & Transcode

> Depends on: ADR-060 to ADR-070 (the Phone Sync arc), especially ADR-066 (file serving) and ADR-070 (the additive-endpoint pattern).
> Binding docs: `_standards.md`; `bocan-music-android/docs/design-spec/sync-protocol.md` (the normative wire contract, edited first in both repos); the schema discipline in the root `CLAUDE.md`.
> Requested by @go1968 in bocan-music#378: "it would be ideal for me to have my main 16-bit flac audio library on my Mac, yet sync it to my phone in 320kbps mp3."

## Goal

Let the Mac keep its lossless library while serving the paired phone smaller, transcoded files, without the Mac itself growing a second library-sized folder. The user picks a quality rung in Phone Sync settings, sees a live estimate of what the synced library will cost the phone in storage at each rung, and the sync machinery does the rest: files above the target are transcoded just ahead of the phone's demand, served, verified, and then released, so the Mac's steady-state disk cost is near zero. Files at or below the target pass through untouched, and the manifest always tells the truth about the bytes served.

One rule carries the quality side: **the phone never stores audio above the chosen target bitrate.** Lossless sources are always transcoded (except at the Original rung); lossy sources are transcoded only when their bitrate exceeds the target. That single predicate answers both "transcode my FLACs" and "should a 320 kbps MP3 be shrunk further" with no extra toggles.

And one split carries the disk side: **the ledger is permanent, the bytes are transient.** The manifest's `size` and `sha256` come from a small database ledger written at encode time; the encoded files themselves exist only between preparation and successful delivery, unless the user opts to keep them.

## Non-goals

- **Per-device presets.** The setting is Mac-global, like the rest of `SyncProfile`. `TrustedDevices` carries no preferences today and gains none here. (Handoff item.)
- **Podcast transcoding.** Episodes are already lossy and their manifest entries carry no format or bitrate fields. Out of scope.
- **On-the-fly streaming transcode.** The protocol requires `Content-Length` (no chunked encoding, `sync-protocol.md` section 4) and the client verifies the manifest's `sha256` against the received bytes, so a served artifact must exist, sized and hashed, before its bytes go on the wire. Prepare-and-release gets disk to near zero *within* that contract; true streaming would be a protocol v2 in both repos for no additional benefit.
- **Multiple rungs at once.** Changing the preset invalidates the ledger for the old one.
- **A protocol version bump.** Everything here fits the contract's additive rules; see Manifest semantics below.

## Definitions and contracts

### Presets

A `TranscodePreset` enum, raw-value stable for persistence:

| Preset | Codec / container | Target | Rationale |
|---|---|---|---|
| `original` | none | pass-through | Today's behaviour; the default. |
| `mp3_320` | MP3 CBR 320 (libmp3lame) | 320 kbps | The compatibility answer, and the literal request. |
| `mp3_256` | MP3 CBR 256 (libmp3lame) | 256 kbps | A meaningful step down for MP3 loyalists. |
| `opus_192` | Opus VBR 192 (libopus, Ogg) | 192 kbps | Transparent to nearly everyone, ~40% smaller than MP3 320. |
| `opus_128` | Opus VBR 128 (libopus, Ogg) | 128 kbps | Rivals MP3 320 quality at 40% of the size; the honest recommendation. |

MP3 rungs are CBR so the size estimate is near-exact. Opus is (constrained) VBR by nature; estimates carry a "≈". Opus output is resampled to 48 kHz (a codec requirement); MP3 output caps at 48 kHz. Hi-res sources (96 kHz / 24-bit) downsample accordingly via `swresample`, the same library the decoder path already uses.

Media3 on the phone decodes MP3 and Ogg Opus natively on any supported Android, before its FFmpeg extension is consulted. Gapless: Opus carries pre-skip in-band and is safe; MP3 gapless depends on the LAME/Xing delay-and-padding header, which FFmpeg's MP3 muxer writes by default. The settings copy notes that Opus is the better choice for gapless albums.

### The transcode predicate

A track is transcoded under a non-`original` preset iff:

```
track.isLossless == true  OR  track.bitrate > preset.targetKbps
```

Everything else passes through byte-identical, exactly as today. Consequences worth stating:

- A 192 kbps MP3 under the `mp3_256` rung passes through. Nothing is ever transcoded *up*.
- A 320 kbps MP3 under `opus_128` is re-encoded. Lossy-to-lossy costs some quality; the rule is the user's explicit choice of ceiling, and the top rungs never touch existing MP3s.
- Exotic lossless formats the phone would need its FFmpeg extension for (APE, WavPack, DSD) come out the other side as MP3/Opus, which is a quiet compatibility win.
- A track with `bitrate` NULL and `isLossless` NULL or false passes through (we cannot judge it; serving the original is the safe wrong answer).

### The ledger

A new Persistence table `sync_transcodes` (see Schema below): one row per (track, preset), recording which source `content_hash` the artifact was derived from and the artifact's `sha256`, `size`, and serve state. The row is written once, at encode time, and **outlives the artifact bytes**: it is what `ManifestBuilder` and the size estimate consult, so the manifest hot path never touches a file and never hashes anything (ADR-070's top gotcha, inherited verbatim).

A row is valid only while its `source_content_hash` matches the track's current `content_hash`. Retag or replace a file and the row is invalidated; the next coordinator pass re-encodes and the phone picks the change up through the normal generation and `sha256` machinery. Switching preset invalidates every row for the old rung and deletes any bytes still on disk.

### The workspace: prepare-and-release

Artifact bytes live in `<Application Support>/Bocan/SyncTranscodes/<preset>/<trackID>-<first 12 of source content_hash>.<ext>`, and their lifecycle is:

1. **Prepare.** The coordinator encodes the artifact, hashes it, writes the ledger row. The track becomes advertisable.
2. **Serve.** `FileServing` streams it on request, `ETag` = the ledger's `sha256`, ranges and `If-Match` exactly as ADR-066 specifies.
3. **Release.** When a response has delivered the artifact **through EOF** (a full 200, or the 206 that reaches the final byte), `FileServing` stamps the ledger's `served_at`; the coordinator's sweep then deletes the bytes. The row, hash, and size remain.

Two policies bound the disk:

- **The prepare window.** The coordinator never holds more than a fixed budget of un-served artifact bytes (default 5 GB). When the window is full it pauses encoding until the phone drains it. A sync therefore interleaves: encode ahead, phone pulls, bytes released, encode continues. If the phone is offline mid-pass, preparation simply parks at the window and resumes when the phone returns; nothing accumulates beyond the budget. The keep-artifacts toggle lifts the window entirely: the user has opted into the disk cost, so the whole selection prepares up front. While the window is parked full, the settings progress row says so instead of implying conversion has stalled.
- **Keep prepared copies (optional).** A single settings toggle, off by default: "Keep prepared copies for faster re-syncs (≈ N GB)". On, step 3 skips deletion and a re-sync or second pairing is instant at the cost of the full transcoded size on the Mac. Off, the steady state is an empty workspace and a few-hundred-MB high-water mark during an active sync.

**Re-encode on demand, and why it self-heals.** A request may arrive for a track whose row exists but whose bytes were released (phone wipe, reinstall, a future second device). The server replies `503 busy` with `Retry-After` (already sanctioned by the protocol for "not ready yet") and queues that track at the head of the coordinator's work. Encoders are not bit-stable across versions, so the fresh artifact's hash may differ from the row's: the coordinator updates the row and bumps the generation. The client's next attempt sends `If-Match` with the old hash, draws the contract's `412`, re-fetches the manifest, and retries against the new hash. Every leg of that dance is existing, specified behaviour on both sides; no Android changes are needed.

The workspace is Application Support, not Caches: bytes inside the prepare window are promised to the phone (`sha256`, `If-Match`) and macOS purging Caches under disk pressure would break that promise mid-transfer. The directory is marked excluded from Time Machine (`CSBackupIsExcluded`); it is derived data either way.

### The transcode coordinator

An actor in `SyncServer` (`TranscodeCoordinator`), started with the server, idle unless the profile names a non-`original` preset:

- Diffs the current selection against the ledger; encodes what lacks a valid row (and re-encodes released-but-requested tracks first), one file at a time, at `.utility` priority, `Task.checkCancellation()` per packet loop (binding, `_standards.md` Concurrency). One encoder at a time and the prepare window together keep the perf baselines honest; a settings progress line ("Prepared 1,234 of 15,000 songs") makes the pass legible, mirroring the existing "Ready to sync" hashing row.
- Source files are read under `SecurityScope.withAccess(bookmark)`, exactly as `FileServing` does. No raw security-scope calls.
- Runs the release sweep: deletes bytes for rows stamped `served_at` (unless the keep toggle is on), for invalidated rows, and for tracks that left the selection. The ledger never advertises what the workspace cannot produce on demand.
- Each ledger write lands in a table observed by `LibraryChangeObserver`, so `generation` bumps (debounced 5 s) and the phone discovers newly prepared tracks on its next poll. The sync grows as the pass progresses; nothing blocks on the whole library being ready.
- Tags: title, artist, album artist, album, track/disc numbers, date, and genre are copied into the artifact's metadata so the file is self-describing off-device. Artwork is not embedded; it ships separately by hash, as ever.

### Manifest semantics: describe the served bytes

Under a non-`original` preset, a track that the predicate marks for transcoding is included in the manifest **only once it has a valid ledger row** (the same shape of gate as today's missing-`content_hash` rule), and its file-describing fields describe the artifact:

- `relPath`: extension swapped to the artifact's (`.mp3` / `.opus`). The client stores by `relPath` and treats it as opaque; identity is `id`, so this is safe, and it keeps bytes and filename agreeing on the phone.
- `size`, `sha256`, `format`, `bitrate`: the ledger's values. The client's storage accounting, change detection, `If-Match`, and post-download verify all keep working unmodified.
- `sampleRate`, `bitDepth`, `channelCount`, `isLossless`: the artifact's values (`bitDepth` null for lossy, `isLossless` false).
- New **additive** field `sourceFormat` (optional string, e.g. `"flac"`): what the Mac holds, for the phone's Song Details sheet. Additive fields need no version bump and clients must ignore unknowns (`sync-protocol.md` section 10).

Pass-through tracks are unchanged in every field. `sync-protocol.md` gains a short normative section stating that file-describing fields always describe the served bytes, and noting the `503 busy` reply on a released artifact, edited in both repos before the Mac implementation lands, per that document's own rule.

### Settings and the size estimate

The Phone Sync settings pane gains a "Quality on phone" picker below the existing profile section, plus the keep toggle and, while a pass runs, the progress line. Each rung shows a live estimate for the *current selection*:

```
estimate = Σ passthrough fileSize  +  Σ transcoded (durationMs / 1000 × targetKbps × 125)
```

One SQL aggregate over the selection, grouped by the predicate; no throwaway manifest builds (the existing `sizeEstimate(for:)` builds and discards an entire manifest, a trap this query must not inherit; fixing that call site to use the same aggregate is in scope). MP3 rungs are near-exact; Opus rungs are ≈. Estimates update when the selection changes, so "how low do I need to go?" is answered by reading the picker. The keep toggle shows the same figure as the disk it would spend on the Mac. All new copy through `L10n` with catalog keys and `make pseudolocale`, as ever.

### Module placement

The encoder (`AudioTranscoder`: demux, decode, resample, encode, mux, hash, all in-process libav*) lives in `AudioEngine`, which owns the CFFmpeg idiom, the serial-executor pattern, and the build flags. `SyncServer` gains an `AudioEngine` dependency: a new lateral edge, acyclic, added to the dependency table in `_standards.md` in the same commit. No new dylibs: the bundled `libavcodec` already links `libmp3lame` and `libopus`, and `embed-deps.sh` resolves them transitively. No spawned `ffmpeg` CLI, which library validation would reject anyway.

### Schema

`M053_SyncTranscodes` adds:

```sql
CREATE TABLE sync_transcodes (
    track_id            INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    preset              TEXT    NOT NULL,
    source_content_hash TEXT    NOT NULL,
    sha256              TEXT    NOT NULL,
    size                INTEGER NOT NULL,
    bitrate             INTEGER,
    created_at          INTEGER NOT NULL,
    served_at           INTEGER,
    PRIMARY KEY (track_id, preset)
);
```

Written by `TranscodeCoordinator` (rows) and `FileServing` (`served_at`), read by `ManifestBuilder`, `FileServing`, and the coordinator's sweep, with tests asserting real non-default values land in every column, and `docs/data-dictionary-notes.json` entries tracing each column to this ADR. The migration ships in the same phase as its writers and readers, per the schema discipline.

## Implementation plan

1. **Protocol first.** Amend `sync-protocol.md` in the Android repo: served-bytes semantics for file-describing fields, the additive `sourceFormat` field, the `503 busy` reply for a not-currently-materialised artifact, no version bump. Commit (Android repo).
2. **Schema.** `M053_SyncTranscodes`, `SyncTranscodeRepository` (upsert, valid-row lookup by track+preset+source hash, stamp served, invalidate by preset, delete stale), migration-count and schema tests, data-dictionary entries. Commit.
3. **Encoder.** `TranscodePreset` and `AudioTranscoder` in `AudioEngine`: fixture WAV in, MP3/Opus out, verified by re-decoding and probing (duration within tolerance, codec, sample rate, tags present), never by golden bytes (encoder output is not bit-stable across FFmpeg versions). Cancellation test. Commit.
4. **Workspace and coordinator.** `TranscodeStore` (root-injectable for tests, like `DownloadStore`; Time Machine exclusion), `TranscodeCoordinator` in `SyncServer` with the prepare window and release sweep, `sync_transcodes` added to the observed-tables list so generation bumps. `SyncProfile` gains the preset and keep-toggle as new fields in the opaque JSON blob (no migration; absent means `original`). The duplicated profile-membership walk (`FileServing.isTrackInProfile` vs `ManifestBuilder`) is extracted into one shared helper here, since the coordinator becomes its third consumer. Commit.
5. **Serving the truth.** `ManifestBuilder` consults the ledger (artifact fields, `sourceFormat`, the valid-row gate) and `FileServing` serves artifacts with ledger ETags, stamps `served_at` on delivery through EOF, and answers `503 busy` + `Retry-After` for a valid row whose bytes are released, queueing the re-encode. The `_standards.md` dependency table gains the SyncServer → AudioEngine edge. Commit.
6. **Settings.** The quality picker with live per-rung estimates via the new aggregate (and `sizeEstimate` reworked onto it), the keep toggle, the prepared-progress line, localized copy, `make pseudolocale`. Commit.
7. **Docs and release note.** README Phone Sync section, website phone-sync page, CHANGELOG Unreleased entry written for the listener. Commit.

## Context7 lookups

- use context7: FFmpeg libavcodec audio encoding: avcodec_find_encoder, avcodec_send_frame/avcodec_receive_packet, encoder frame_size handling
- use context7: FFmpeg libavformat muxing: avformat_alloc_output_context2, avformat_write_header, av_interleaved_write_frame, writing metadata dictionaries
- use context7: FFmpeg swresample: swr_alloc_set_opts2 for sample-rate and channel-layout conversion feeding an encoder
- use context7: AndroidX Media3 ExoPlayer supported audio formats and gapless playback metadata requirements

## Test plan

- **AudioTranscoder** (AudioEngine): WAV fixture to each preset; probe codec, sample rate, channel count, tag round-trip; duration within 100 ms of source; Opus output is 48 kHz; cancellation mid-encode leaves no partial artifact at the destination path.
- **SyncTranscodeRepository** (Persistence): upsert/lookup/invalidation by source hash; served stamping; invalidate-by-preset; cascade on track delete.
- **TranscodeCoordinator** (SyncServer): selection diffing (encodes missing, skips valid, releases served, deletes deselected and invalidated); the prepare window pauses and resumes around the budget; predicate table (lossless, high lossy, low lossy, NULL-bitrate); generation bump on row writes; preset switch clears the old rung; keep-toggle suppresses release.
- **ManifestBuilder / FileServing** (SyncServer): manifest describes ledger fields and gates on valid rows; pass-through tracks byte-identical to today; ETag/If-Match against ledger hash; `503 busy` for released bytes; the self-heal sequence (re-encode with a new hash, 412 on stale If-Match, fresh manifest carries the new hash); 412 when the source changed under a stale manifest.
- **Estimate**: the aggregate matches a hand-computed fixture library for each rung, pass-through and transcode mixed.
- **UI** (make test-ui): source-convention tests for the picker, keep toggle, and progress line; L10n and pseudolocale coverage.
- No golden encoded bytes anywhere; no network; fixtures deterministic and checked in.

## Acceptance criteria

- [ ] `sync-protocol.md` amended in the Android repo before any Mac serving change lands.
- [ ] With `original` selected (and by default), every byte served is identical to today; the whole feature is invisible.
- [ ] Selecting a rung shows a per-rung size estimate for the current selection without building a manifest.
- [ ] A FLAC library syncs as MP3 320 / 256 / Opus 192 / 128 per the chosen rung; files at or below the target pass through untouched.
- [ ] With the keep toggle off (default), the workspace is empty after a completed sync and never exceeds the prepare window during one.
- [ ] With the keep toggle on, a wiped phone re-syncs without re-encoding.
- [ ] A request for released bytes draws `503 busy`, and the subsequent re-encode/412/re-fetch sequence completes without user intervention.
- [ ] The phone verifies, stores, and plays transcoded files with no Android code changes; Song Details may later show `sourceFormat`.
- [ ] Retagging a synced file re-encodes its artifact and the phone picks up the change via the normal generation/`sha256` path.
- [ ] Preset switch reclaims the old rung's rows and bytes; deselecting content reclaims its artifacts.
- [ ] `make format && make lint && make build && make test-audio-engine && make test-persistence && make test-sync-server && make test-ui && make test-coverage` green; data dictionary complete; `make audit-db` clean.

## Gotchas

- **Never hash or probe on the manifest path.** The ledger exists so `/v1/manifest` stays free of file I/O; ADR-070 learned this the hard way for artwork.
- **The ledger outlives the bytes; the bytes must not outlive the promise.** Un-served artifacts inside the prepare window are covered by `sha256`/`If-Match` promises, so the workspace stays in Application Support (Caches can be purged mid-transfer) and is Time-Machine-excluded. Released bytes are the *normal* state, handled by `503 busy` + self-heal, never by pretending the row does not exist.
- **"Served through EOF" is the release signal, not "the phone verified it".** If the phone's verify fails it re-requests, hits the 503/re-encode path, and self-heals; do not build an acknowledgement endpoint for this.
- **Encoder output is not bit-stable across FFmpeg versions.** A re-encode may change the hash; the 412 path absorbs it. Never golden-file encoded bytes in tests.
- **The perf baselines still apply.** One encode at a time, `.utility`, cancellation-checked. The idle-CPU baseline refers to the app at rest; an active preparing pass is visible work with a visible progress line, but it must not audibly compete with playback.
- **MP3 gapless is metadata-fragile.** Keep the LAME/Xing header intact through the muxer; steer gapless-sensitive users to Opus in the settings copy.
- **Debug and release builds have separate Application Support trees** (see root CLAUDE.md): a debug run builds its own ledger and workspace and says nothing about the release ones.
- **`SyncProfile` is an opaque JSON blob by design.** The preset and keep toggle ride inside it; do not add a Persistence-visible column for them. A profile edit already bumps the generation for free.

## Handoff

- Per-device presets (schema on `trusted_devices`, per-device manifests) if a second paired device ever wants a different rung.
- Podcast episode transcoding, if anyone ever asks; it needs format/bitrate fields on Episode first.
- A "transcode imported exotics for the Mac itself" feature could reuse `AudioTranscoder` wholesale; nothing here precludes it.
- If re-encode-on-demand latency ever annoys in practice, a small pinned LRU ("keep the last N GB served") slots between the toggle's all-or-nothing extremes without touching the protocol.
