# Phase 9 — Multi-Band EQ, ReplayGain & Audio Effects

> Prerequisites: Phases 0–8 complete. `AudioEngine` exposes an `AudioGraphInsertionPoint` (Phase 1).
>
> Read `phases/_standards.md` first.

## Goal

A proper DSP chain: 10-band EQ, bass boost, headphone crossfeed, stereo expansion, soft limiter. ReplayGain computation for tracks missing tags, applied correctly at playback. Presets (built-in + user). A/B compare. Per-track / per-album / global EQ assignment.

## Non-goals

- Convolution reverb / impulse responses — out of scope.
- Parametric EQ beyond 10 bands — stretch goal only.
- Per-output-device EQ profiles — noted as a future enhancement, not v1.
- DSP plug-ins (AU, VST) — out of scope.

## Outcome shape

```
Modules/AudioEngine/Sources/AudioEngine/DSP/
├── DSPChain.swift                   # Builds and maintains the chain
├── EQUnit.swift                     # AVAudioUnitEQ wrapper with preset management
├── BassBoostUnit.swift              # Low-shelf via AVAudioUnitEQ second instance
├── CrossfeedUnit.swift              # Custom AUAudioUnit (Bauer crossfeed)
├── StereoExpanderUnit.swift         # Custom AUAudioUnit (mid/side matrix)
├── LimiterUnit.swift                # AVAudioUnitDistortion? No — use AVAudioUnitEffect (peak limiter)
├── GainStage.swift                  # Per-track ReplayGain application
└── Presets/
    ├── EQPreset.swift
    ├── BuiltInPresets.swift
    └── PresetStore.swift            # persist in settings table

Modules/AudioEngine/Sources/AudioEngine/ReplayGain/
├── ReplayGainAnalyzer.swift         # EBU R128 implementation
├── EBUR128.swift                    # K-weighted loudness, gating
└── GainApplication.swift            # Resolves which gain to use at playback time

Modules/UI/Sources/UI/DSP/
├── EQView.swift                     # 10 sliders + bypass + A/B + preset picker
├── DSPView.swift                    # Crossfeed, expansion, bass boost toggles
├── PresetManagerView.swift
└── ReplayGainSettingsView.swift
```

## Implementation plan

### Chain topology

```
DecoderOutput → PlayerNode → GainStage (RG) → EQ → BassBoost → Crossfeed → StereoExpander → Limiter → OutputNode
```

All nodes exist in the graph at all times; each can be bypassed without rebuilding the graph (avoids audible glitches when toggling).

1. **Gain stage** — an `AVAudioMixerNode` (or a small custom AU) that applies a linear gain equal to `10^(rg_db/20)`. Updated on track change.

2. **EQ unit** — `AVAudioUnitEQ(numberOfBands: 10)`:
   - Bands at ISO centre frequencies: 31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
   - Filter types: first and last as `.parametric` with Q ~ 0.7 (or `.lowShelf` / `.highShelf` optionally); middle as `.parametric`.
   - Gain per band: ±12 dB range, default 0.
   - Overall output gain: ±12 dB.
   - `bypass = true` when globally disabled; individual bypass per band not exposed (keeps UI simple).

3. **Bass boost** — a dedicated low-shelf band via a second `AVAudioUnitEQ(numberOfBands: 1)` (keeps it decoupled from the main EQ so presets don't clash with the toggle). Gain 0–12 dB, frequency 80 Hz fixed, Q 0.7. Off by default.

4. **Crossfeed** — Bauer stereo-to-stereo matrix with two IIR low-pass filters. Implement as a custom `AUAudioUnit` subclass with a single user parameter `amount: 0…1`. Bypassable. Include an academic citation in the source comments (Bauer 1961 / Jan Meier's implementation).

5. **Stereo expander** — mid/side matrix: decode L/R to M/S, scale S by `width: 0.5…2.0` (1.0 = unchanged), re-encode. Implement as another small custom AU.

6. **Limiter** — prevents post-EQ clipping. Use `AVAudioUnitEffect` with a built-in peak limiter preset, or implement a soft-knee brickwall. Always enabled; threshold at −0.3 dBFS, release ~50ms.

7. **Graph insertion** — `AudioEngine` exposes an ordered list of insertion points. `DSPChain` inserts its nodes at construction. Order is stable.

### ReplayGain

8. **`EBUR128`** — implement K-weighted loudness measurement per ITU-R BS.1770-4:
   - Apply pre-filter (high-pass + high-shelf).
   - Mean-square over 400ms windows, 75% overlap.
   - Gating: absolute (-70 LUFS) then relative (-10 LU below ungated mean).
   - Integrated loudness in LUFS.
   - True peak per channel via 4× oversampling (simple polyphase).
   - Store results as `R128` values, convert to ReplayGain 2.0: `gain = -18 - integrated_lufs` (target −18 LUFS); peak in linear.

9. **`ReplayGainAnalyzer`** — driver that decodes a track (re-use `DecoderFactory`), pumps samples through `EBUR128`, returns `(trackGain, trackPeak)`. Album mode: aggregate across a set of tracks' measurements, produce `(albumGain, albumPeak)`.

10. **Computation flow**:
    - Background operation, triggered:
      - User action: "Compute Replay Gain" on selection or album.
      - Tools menu: "Compute Missing Replay Gain" — finds tracks without RG values, processes N at a time with progress.
    - Results written into the DB (`tracks.replaygain_*` columns).
    - Optionally written back into file tags (setting-gated; default **off**). Vorbis comments, ID3v2 `TXXX:REPLAYGAIN_*`, Opus `R128_*` (converted to Q7.8), etc.

11. **`GainApplication`** — resolves which gain to use at playback time:
    - Mode preference (setting): `off` | `track` | `album` | `auto`.
    - `auto`: if part of a queued album span, use album gain; otherwise track gain.
    - Pre-amp setting (±12 dB) applied on top.
    - Clipping guard: if `track_gain + pre_amp` would push peak above −0.5 dBFS (using `replaygain_track_peak`), reduce gain by the difference. Document.
    - Value written to the `GainStage` on every track change.

### UI

12. **`EQView`**:
    - 10 vertical sliders labelled by frequency; slider tracks show dB grid lines at ±6/±12.
    - Overall output-gain slider at the right.
    - Bypass checkbox (toggles `EQ.bypass`).
    - A/B button: toggles between the current preset and "flat"; tap-and-hold toggles while held.
    - Preset picker (menu): built-in + user presets; "Save as Preset…" and "Manage Presets…".
    - Scope picker: Global / Current Album / Current Track. Stored in a `track_dsp_assignments` table added via migration M004:
      ```sql
      CREATE TABLE track_dsp_assignments (
          track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
          eq_preset_id TEXT,
          bass_boost_db REAL,
          crossfeed_amount REAL,
          stereo_width REAL,
          PRIMARY KEY (track_id)
      );
      CREATE TABLE album_dsp_assignments (
          album_id INTEGER REFERENCES albums(id) ON DELETE CASCADE,
          eq_preset_id TEXT,
          PRIMARY KEY (album_id)
      );
      ```

13. **`DSPView`** — toggles + sliders for bass boost, crossfeed amount, stereo width.

14. **`PresetManagerView`** — rename, duplicate, delete user presets; cannot mutate built-ins.

15. **`ReplayGainSettingsView`** — pick mode, pre-amp, enable write-back-to-file toggle, "Compute missing" action, "Recompute all" (with confirm).

## Built-in presets

Name, per-band dB array (31.5 → 16k), overall gain, notes:

- **Flat**: `[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]`, 0 dB.
- **Rock**: `[4, 3, -2, -3, -1, 2, 4, 5, 5, 4]`.
- **Jazz**: `[2, 2, 1, 0, -1, -1, 0, 1, 2, 3]`.
- **Classical**: `[0, 0, 0, 0, 0, 0, -2, -2, -2, -3]`.
- **Electronic**: `[5, 4, 1, 0, -2, 2, 1, 1, 4, 5]`.
- **Vocal Boost**: `[-2, -2, -1, 1, 3, 3, 2, 1, 0, -1]`.
- **Bass Boost**: `[6, 5, 3, 1, 0, 0, 0, 0, 0, 0]`.
- **Treble Boost**: `[0, 0, 0, 0, 0, 1, 3, 5, 6, 6]`.
- **Loudness**: `[6, 4, 1, 0, -2, -1, 0, 1, 4, 6]`.
- **Spoken Word**: `[-4, -3, 0, 2, 4, 3, 2, 1, -1, -2]`.

## Definitions & contracts

### `EQPreset`

```swift
public struct EQPreset: Sendable, Codable, Hashable, Identifiable {
    public let id: String                 // built-ins: "bocan.flat"; user: UUID string
    public let name: String
    public let bandGainsDB: [Double]      // 10 entries
    public let outputGainDB: Double
    public let isBuiltIn: Bool
}
```

### `DSPState`

```swift
public struct DSPState: Sendable, Codable, Hashable {
    public var eqEnabled: Bool
    public var eqPreset: EQPreset.ID?
    public var bassBoostDB: Double
    public var crossfeedAmount: Double    // 0...1
    public var stereoWidth: Double        // 0.5...2.0
    public var replayGainMode: ReplayGainMode
    public var preAmpDB: Double
}
```

## Context7 lookups

- `use context7 AVAudioUnitEQ filterType parametric band`
- `use context7 AUAudioUnit subclass internal render block`
- `use context7 vDSP biquad IIR filter`
- `use context7 ITU-R BS.1770 K-weighting EBU R128 Swift`
- `use context7 Swift Accelerate true peak oversampling`

## Dependencies

None new at Swift level. Uses `Accelerate` (system).

## Test plan

### EQ

- Process white noise through each preset; measure power in ISO-band sliding windows; verify within ±1 dB of target.
- Bypass produces sample-exact output (within float epsilon) vs input.
- Changing a band while audio flows introduces no discontinuity > −60 dB click (measured via moving RMS).
- Preset load/save round-trip.

### Crossfeed / expander

- Crossfeed at amount=0 is transparent (bit-exact bypass).
- At amount=1, stereo width measurement (correlation between L and R) increases from ≈0 (hard-panned sine pair) to > 0.5.
- Stereo expander at width=1 is identity; at width=0 collapses to mono (L==R).

### Limiter

- Feed a +6 dB sine ramp; output never exceeds −0.3 dBFS.
- Release behaviour: after a peak, gain returns to unity within the configured release time.

### ReplayGain / EBU R128

- Reference signals:
  - 1 kHz sine at −20 dBFS → −23.03 LUFS (documented R128 reference).
  - EBU conformance files (if licensable) or hand-computed fixtures → within ±0.1 LU.
- Track-gain calculation: track peak matches sample-accurate peak within 0.1 dB.
- Album-gain aggregation: matches reference tool (e.g. `rsgain`) within 0.1 dB on a fixture album.
- Applying gain at playback yields the expected linear amplitude change (measured via tap).

### Clipping guard

- A track with `peak = −0.1` and `gain = +6` is clamped so output doesn't exceed −0.5 dBFS; log emitted.

### UI

- Snapshot: EQ view flat and with a preset, light + dark.
- Preset menu shows built-ins first, then user.
- Scope switcher: setting a per-track assignment writes to DB, reverts to global after track change when on "Global".
- A/B toggle flips EQ + gain path cleanly; no audible pop.

### Performance

- EQ adds < 2% CPU on a typical M-series Mac during playback.
- Analysing a 3-minute track takes < 10s on a single thread; parallelisable.

## Acceptance criteria

- [ ] 10-band EQ with instantly-responsive sliders.
- [ ] Bypass is truly transparent.
- [ ] Presets save and load; per-track and per-album assignments persist.
- [ ] Replay Gain prevents loudness whiplash between tracks.
- [ ] Clipping guard triggers when it should.
- [ ] Headphone crossfeed and stereo expansion sound sensible (manual check) and measurements match intent.
- [ ] 80%+ coverage on DSP + RG code.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **Custom AUs + Swift 6**: `AUAudioUnit` internal render block is real-time audio — **no allocations, no locks, no Swift-runtime metadata lookups**. Write the render block in C or as a Swift function with `@_transparent`/unsafe pointers only; pre-allocate all state. Test with `AVAudioEngine`'s `manualRenderingMode` and Thread Sanitiser disabled (TSan isn't RT-safe).
- **Bypass that isn't truly bypass**: `AVAudioUnitEQ` with all-zero gains can still introduce tiny floating-point noise. For the A/B and bypass-check test, toggle the `bypass` property (full bypass in the framework) rather than zero'ing bands.
- **EBU R128 pre-filter**: the standard specifies a two-stage filter. Common open-source implementations (`libebur128`) get the coefficients right; cross-check against reference output and pin the coefficients in a comment.
- **True peak** needs oversampling. 4× is the common compromise; lower is inaccurate, higher is wasted cycles.
- **R128 Opus tags** use Q7.8 fixed-point integer, target −23 LUFS; ReplayGain 2.0 targets −18 LUFS. Converting between them requires adjusting the reference — document and test both directions.
- **Write-back to files**: risky feature. Default **off**. When on, warn on the first run that files will be modified.
- **Chain rebuilds cause dropouts**: never `disconnectNode`/`connect` during playback. Keep all nodes in the graph with per-node `bypass` flags.
- **Threading**: parameter changes go through `AUParameterTree` (KVO-style), which schedules the change on the render thread safely. Don't mutate raw state atomically — use the parameter tree.
- **Sample rate**: filter coefficients depend on sample rate. On device change (Phase 1 already reconfigures the engine), recompute all filter coefficients.
- **UI sliders → parameters**: avoid writing on every `onChange`; debounce at ~30 Hz (enough for smooth response) to save CPU.
- **Per-album assignments** interact with smart shuffle: a track played out of its album context may or may not use the album preset — decide and document. Suggested: album preset wins when queued as part of an album span.

## Handoff

Phase 10 (Mini Player + Polish) expects:

- `DSPView`, `EQView`, `ReplayGainSettingsView` are composable as settings panels.
- Current DSP state is an observable `@MainActor` object the mini-player can subscribe to for showing an "EQ on" indicator.
