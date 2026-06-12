# Phase 12.1: Visualizer Foundations (Analysis v2 + Dynamic Palettes)

> Prerequisites: Phase 12 complete. `AudioTap` + `FFTAnalyzer` exist and feed
> `VisualizerViewModel`. `SpectrumBars` and `Oscilloscope` render from `Analysis`.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Shared groundwork for the four new visualizer modes (phases 12.2 to 12.5):

1. **Analysis v2**: enrich the per-frame analysis with spectral centroid, spectral
   flux, onset (beat) detection, and bass/mid/treble energy aggregates, all derived
   from the existing audio tap. No new taps, no synthetic animation data; every
   feature is computed from the real FFT magnitudes already in hand.
2. **`PaletteResolver`**: one shared colour-mapping helper replacing the duplicated
   palette `switch` statements in `SpectrumBars.bandColor` and
   `Oscilloscope.lineColor`. All current and future visualizers resolve colour
   through it, so the existing settings picker ("the current method") controls
   every mode.
3. **Two new palettes** for motion-heavy modes where the four static palettes feel
   flat: `drift` (slowly evolving hue, steered by the music) and `thermal`
   (magnitude-to-heat colour ramp).
4. **Render-time injection**: pass the frame timestamp into `Visualizer.render` so
   animated modes and dynamic palettes stay deterministic in snapshot tests.

## Non-goals

- No new visualizer modes here (those are 12.2 to 12.5).
- No tempo/BPM estimation; onset detection is per-event, not periodic.
- No per-visualizer palette overrides; one global palette setting remains.

## Outcome shape

```
Modules/AudioEngine/Sources/AudioEngine/Tap/
└── FFTAnalyzer.swift                # analyze(_:) now returns SpectrumFrame

Modules/UI/Sources/UI/Visualizers/
├── Visualizer.swift                 # Analysis gains v2 fields; render(...) gains time
├── PaletteResolver.swift            # NEW: shared palette -> Color mapping
└── SpectrumBars.swift               # VisualizerPalette gains .drift, .thermal
```

## Definitions and contracts

### `SpectrumFrame` (AudioEngine)

`FFTAnalyzer.analyze(_:)` changes its return type from `[Float]` to:

```swift
public struct SpectrumFrame: Sendable {
    /// 32 perceptual bands, 0...1 (unchanged semantics).
    public let bands: [Float]
    /// Spectral centroid on a log-frequency scale, 0...1
    /// (0 = 20 Hz, 1 = 20 kHz). EMA-smoothed; relaxes toward 0.5 in silence.
    public let centroid: Float
    /// Positive spectral flux, normalised 0...1 by a running flux peak.
    public let flux: Float
    /// True when this frame contains a detected onset (transient).
    public let onset: Bool
    /// Mean of bands 0..<10, 10..<22, 22..<32 respectively, each 0...1.
    public let bassEnergy: Float
    public let midEnergy: Float
    public let trebleEnergy: Float
}
```

Computation details, all inside `FFTAnalyzer` (already `@MainActor`, never on the
RT thread):

- **Centroid**: from the raw 1024 squared-magnitude bins (not the 32 bands):
  `sum(freq_i * mag_i) / sum(mag_i)`, then mapped through
  `(log10(c) - log10(20)) / (log10(20000) - log10(20))`, clamped 0...1, smoothed
  with EMA alpha 0.2. When total magnitude is below 1e-7, decay toward 0.5.
- **Flux**: `sum(max(0, rawBand[i] - prevRawBand[i]))` over the *pre-EMA* band
  values (the smoothed values smear transients). Normalised by a running flux
  peak with the same decay trick used by `bandPeaks`.
- **Onset**: `flux > 1.8 * movingAverage(flux, window: 43 frames)` AND
  `flux > 0.05` absolute floor, with a 4-frame (about 100 ms) refractory period
  so one kick drum produces one onset.
- **Energy triple**: arithmetic means over the stated band ranges of the final
  normalised band values.

`reset()` clears the new state (prev bands, flux average, refractory counter,
centroid EMA).

### `Analysis` v2 (UI)

`Analysis` gains the same six fields, populated 1:1 from `SpectrumFrame` in
`VisualizerViewModel.processSamples`. `Analysis.silent` sets centroid 0.5 and
everything else 0/false.

### `Visualizer.render` signature

```swift
func render(
    into context: inout GraphicsContext,
    size: CGSize,
    samples: AudioSamples,
    analysis: Analysis,
    time: TimeInterval            // NEW: TimelineView date, seconds
)
```

`VisualizerHost.timelineCanvas` passes `tl.date.timeIntervalSinceReferenceDate`.
Renderers that animate keep a `lastTime` and derive `dt` themselves (clamped to
0...0.1 s to survive pauses). Snapshot tests pass fixed times.

### `PaletteResolver` (UI)

```swift
public enum PaletteResolver {
    /// Colour for an element of a visualizer.
    /// - position: 0...1 placement of the element (band fraction, angle fraction).
    /// - magnitude: 0...1 intensity of the element.
    public static func color(
        palette: VisualizerPalette,
        position: Double,
        magnitude: Float,
        analysis: Analysis,
        time: TimeInterval
    ) -> Color

    /// Evenly spaced gradient stops (count 8) for ramp-style consumers
    /// (Cascade pixel LUT, Nebula density LUT).
    public static func rampStops(
        palette: VisualizerPalette,
        analysis: Analysis,
        time: TimeInterval
    ) -> [Color]
}
```

For the four existing palettes, `color(...)` reproduces the current
`SpectrumBars.bandColor` output byte-for-byte (snapshot tests guard this).
`Oscilloscope` keeps its single-line styling by calling the resolver with
`position: 0` and its current special cases folded in (mono stays white).

### New palettes

```swift
case drift     // displayName: L10n "Drift"
case thermal   // displayName: L10n "Thermal"
```

- **Drift**: `hue = fract(time / 90 + 0.25 * centroid + 0.15 * position)`,
  saturation 0.85, brightness `0.55 + 0.45 * magnitude`. A full hue cycle takes
  90 s; the centroid term makes bright, trebly passages visibly shift the colour.
  Deterministic given (time, analysis), so it is snapshot-testable.
- **Thermal**: position-independent heat ramp indexed by `magnitude`:
  stops at 0, 0.25, 0.5, 0.75, 1.0 are near-black navy, indigo, magenta,
  orange, white-hot. Linear interpolation between stops in sRGB.

`VisualizerPalette` is stored by `rawValue` in `@AppStorage`, so appending cases
is backward compatible.

### Settings

Six palettes no longer fit a segmented control. Change the palette picker in
`VisualizerSettingsView` from `.segmented` to `.menu`. Add catalog keys for
"Drift" and "Thermal" and run `make pseudolocale`.

## Implementation plan

1. `SpectrumFrame` + centroid/flux/onset/energies in `FFTAnalyzer`; update
   `reset()`; migrate `VisualizerViewModel` and analyzer tests. Commit.
2. `Analysis` v2 + `render(... time:)`; mechanical update of `SpectrumBars`,
   `Oscilloscope`, `VisualizerHost`, snapshot tests. Commit.
3. `PaletteResolver` extracted; both existing visualizers refactored onto it;
   snapshot tests confirm zero visual drift for the four existing palettes. Commit.
4. `drift` + `thermal` cases, resolver arms, settings picker change, L10n keys,
   pseudolocale. Commit.

## Context7 lookups

- `use context7 Accelerate vDSP weighted sum spectral centroid`
- `use context7 spectral flux onset detection adaptive threshold`
- `use context7 SwiftUI Picker menu style macOS Form`

## Dependencies

None new.

## Test plan

- **Centroid**: a 100 Hz sine yields centroid < 0.3; a 8 kHz sine yields > 0.75;
  sweeping low to high strictly increases the smoothed centroid.
- **Flux/onset**: silence then a broadband impulse produces exactly one onset;
  a sustained sine produces none after the attack frame; two impulses 2 frames
  apart produce one onset (refractory); two impulses 10 frames apart produce two.
- **Energies**: band-limited noise in the bass range raises `bassEnergy` while
  `trebleEnergy` stays near 0, and vice versa.
- **Reset**: after `reset()`, flux history and centroid EMA restart cleanly.
- **Resolver parity**: snapshot tests for SpectrumBars and Oscilloscope across
  all four legacy palettes are unchanged after the refactor.
- **Drift determinism**: same (time, analysis) input twice gives identical colour;
  advancing time by 45 s moves hue by 0.5 cycle.
- **Thermal ramp**: magnitude 0 maps near-black, 1.0 maps near-white, monotonic
  perceived brightness across the ramp.
- **L10n**: new keys present in the catalog; en-XA coverage test green.

## Acceptance criteria

- [ ] `FFTAnalyzer.analyze` returns `SpectrumFrame`; all listed features tested.
- [ ] `Analysis` carries the v2 fields; `render` receives `time`.
- [ ] `PaletteResolver` is the single palette mapping; no palette `switch`
      remains inside individual visualizers.
- [ ] Existing-palette snapshots unchanged.
- [ ] `drift` and `thermal` selectable in Settings; localized; pseudolocale green.
- [ ] `make lint && make test-coverage && make test-ui && make test-audio-engine` green.

## Gotchas

- **Do the feature math on the consumer side only.** Nothing here touches the
  RT tap block; `FFTAnalyzer` stays `@MainActor`.
- **Flux must use pre-EMA bands.** Computing flux on the smoothed values makes
  onsets mushy and late; keep a separate `prevRawBands` buffer.
- **Adaptive flux normalisation needs a floor**, like `bandPeaks`, or silence
  after a loud passage produces ghost onsets from noise.
- **`Analysis.silent` centroid is 0.5**, not 0, so Drift does not slam to red
  on pause.
- **Picker style change is user-visible**; update the settings snapshot test in
  the same commit.
- **Six palettes, two visualizers, snapshot matrix grows.** Snapshot only the
  new palettes on one canvas size to keep the suite fast.

## Handoff

Phases 12.2 (Halo), 12.3 (Cascade), 12.4 (Starfield), 12.5 (Nebula) expect:

- `Analysis` v2 fields available and tested.
- `PaletteResolver.color` / `rampStops` as the only way they obtain colour.
- `render(... time:)` available for deterministic animation.
