# ADR-075: Transcode Detection (Audio Provenance)

> Prerequisites: ADR-001 to ADR-074 complete. `ReplayGainAnalyzer` (`AudioEngine`)
> decodes whole files offline via `AVAudioFile` for the EBU R128 pass and is
> the infrastructure precedent for this ADR. The Library Summary window
> (#373) exists with a live Audio Quality tab whose SQL slice reports
> distributions, mixed-format albums, and true-peak overs. `Tools` menu and
> batch-job UX precedent: "Compute Missing ReplayGain".
>
> Read `docs/design-spec/_standards.md` first.

## The brief

Every large FLAC collection contains "FLACs" that were transcoded from lossy
sources years ago, and nobody knows which until they look at a spectrogram.
A lossy encoder discards energy above a codec-and-bitrate-dependent ceiling
(roughly 16 kHz for 128k MP3, 19-20 kHz for 320k), and that hard spectral
shelf survives re-encoding to a lossless container. A file claiming lossless
provenance with a lossy shelf is *suspected* of being a transcode.

The product stance, fixed up front: **suspected, never accused.** Live
recordings, old digitisations, dull source material, and legitimately
lossy-mastered releases all false-positive. Every surface says "suspected",
carries a confidence, and explains why it might be wrong.

## Slices

### ADR-075 slice 1: `ProvenanceAnalyzer` (AudioEngine)

Pure analysis, no persistence, no UI.

- Decode N sample windows (default three of ~10 s: at 25%, 50%, 75% of the
  file) using the `AVAudioFile` path from `ReplayGainAnalyzer`; fall back to
  `FFmpegDecoder` for formats AVFoundation refuses, matching
  `DecoderFactory`'s split.
- vDSP FFT per window (Hann window, 8192-point, averaged magnitude spectrum
  per segment; average the segments).
- Shelf heuristic: find the highest frequency band whose average energy sits
  within X dB of the midband reference, then measure the rolloff steepness
  above it. A shelf below ~`0.45 * sampleRate` in a file claiming lossless,
  with a steep cliff (>= Y dB within 2 kHz), scores as suspected. Cliff
  frequency near 16/19/20 kHz raises confidence (known encoder ceilings);
  gradual rolloff (analogue source) lowers it.
- Output: `ProvenanceVerdict { suspected: Bool, confidence: Double (0-1),
  shelfFrequencyHz: Int?, analysedAt }`. `Sendable`, no I/O beyond the
  decode.
- Tests: synthesized PCM only (checked-in-fixture-free): full-band noise
  must pass clean; noise low-passed at 16 kHz inside a 44.1 kHz buffer must
  score suspected with high confidence; gently rolled-off "analogue" noise
  must stay below the suspected threshold. No network, no real music files.

### ADR-075 slice 2: Persistence

- New migration `M0NN_Provenance` (numbered, append-only, registered in
  `Migrator.make()`; update `MigrationTests` counts): three nullable columns
  on `tracks`: `provenance_suspected` (Bool), `provenance_confidence`
  (Double), `provenance_analysed_at` (epoch seconds). Columns, not a side
  table: verdicts are 1:1 with tracks and the summary queries want them
  cheap.
- Repository API on `TrackRepository`: fetch tracks needing analysis
  (lossless, unanalysed or file newer than verdict), write verdicts, clear
  verdicts on file change (the scanner's update path must null them when
  `file_mtime` changes).
- `LibraryStatsRepository+AudioQuality` gains suspected-transcode counts and
  a capped offender list (id, title, albumID, confidence, shelf kHz).

### ADR-075 slice 3: Batch job (App + UI)

- Tools menu: "Analyse Provenance…" following the Compute Missing ReplayGain
  pattern exactly: background task with progress, cancellation via
  `Task.checkCancellation()` in the file loop, `AppLogger` op.start/end
  logging, toast on completion.
- Scope control: analyse only tracks claiming lossless (`is_lossless = 1`);
  lossy-from-lossy detection is explicitly out of scope for this ADR.
- Throttle: one file at a time, utility QoS; a large library is hours, and
  that is fine because verdicts persist.

### ADR-075 slice 4: Surfacing (UI)

- Audio Quality tab gains "Suspected Transcodes (N)" as a disclosure-group
  offender section, present only when at least one track has been analysed;
  rows show confidence ("87% confident · shelf at 16 kHz") and navigate to
  the album via `SummaryOffenderRow`.
- An explanatory footer: what a shelf is, why a verdict can be wrong, in
  plain copy. The word is always "suspected".
- Unanalysed count surfaces beside the section so coverage is honest.
- Stretch, not required for this ADR: a small spectrogram thumbnail per
  suspect (offline render; the Cascade visualizer's spectrogram math is the
  in-repo precedent).

## Non-goals

- No automatic deletion, retagging, or quarantining. Report only.
- No lossy-from-lossy detection (192k MP3 re-encoded to 320k) in this ADR.
- No cloud lookups; everything is computed from local audio.

## Risks

- False positives are certain; the confidence model and copy carry the
  product. Ship conservative thresholds and tune against real libraries.
- FFmpeg-decoded formats need the same PCM contract as AVAudioFile output;
  the analyzer must be sample-rate-aware, not assume 44.1 kHz.
- Battery/thermals on laptops: utility QoS and one-file-at-a-time are load
  policy, not incidental.
