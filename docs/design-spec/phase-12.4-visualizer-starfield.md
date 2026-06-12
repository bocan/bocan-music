# Phase 12.4: Visualizer Mode "Starfield" (Frequency-Coloured Warp Field)

> Prerequisites: Phase 12.1 complete (Analysis v2, `PaletteResolver`,
> `render(... time:)`). Phase 12.3 adds `Analysis.frameIndex` (used here).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A field of stars flying outward from the centre, each star bound to one of the
32 frequency bands: its speed and brightness follow that band's energy, so the
field shimmers in patterns that mirror the spectrum. Loud passages accelerate
the whole field; onsets fire a warp kick that stretches stars into streaks.
The result is constant deep motion ("more movement") that is still entirely
audio-derived: in silence the field drifts almost imperceptibly.

Canvas plus `drawingGroup()`; point sprites, not fluid (that's Nebula's job).

## Non-goals

- No 3D projection math beyond radial perspective fakery.
- No collision, gravity, or particle interaction.
- No Metal; if 500 dots in a `drawingGroup` Canvas cannot hold 60 fps the
  budget is wrong, not the renderer tech.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── Starfield.swift                  # NEW: renderer + particle pool
├── VisualizerMode.swift             # + case starfield
└── VisualizerHost.swift             # + rebuildRenderer arm
```

## Visual design

- **Particles.** 500 stars in a preallocated `ContiguousArray` of structs:

  ```swift
  struct Star {
      var angle: Float          // radians, fixed per life
      var radius: Float         // 0...1.1, normalised to min(w, h)/2
      var size: Float           // 0.8...2.4 pt base
      var bandIndex: Int        // 0...31, uniform distribution
      var twinklePhase: Float   // random 0...2 pi
  }
  ```

  Initialised from a seedable RNG (`init(seed:)`, default random) so snapshot
  tests are deterministic.
- **Motion.** Per frame with `dt` (clamped 0...0.1 s):

  ```
  speed  = base 0.05 + 0.5 * rms + 0.7 * bands[bandIndex] + warpBoost
  radius += dt * speed * (0.3 + radius)      // perspective acceleration
  ```

  A star passing radius 1.1 respawns at radius 0.02 with a fresh random angle.
  In silence the field creeps at the base speed only.
- **Warp kick.** On `analysis.onset` (edge-detected via `frameIndex`),
  `warpBoost` jumps to 2.0 and decays exponentially with a 0.4 s time
  constant. While `warpBoost > 0.5`, each star renders as a streak: a line
  from its previous frame position to its current one, width = star size,
  giving the classic jump-to-lightspeed stretch. Below the threshold, stars
  render as circles of radius `size * (0.6 + 0.6 * bands[bandIndex])`.
- **Twinkle.** Opacity `= fadeIn(radius) * (0.85 + 0.15 * sin(3 * time +
  twinklePhase))`, where `fadeIn` ramps 0 to 1 over radius 0 to 0.15 so
  respawns never pop.
- **Core glow.** A small radial gradient at the centre whose alpha follows
  `bassEnergy` (the engine room of the warp drive).

### Colour (the current method)

Each star's colour comes from
`PaletteResolver.color(palette:position: bandIndex/31, magnitude: bands[bandIndex], ...)`.

- `spectrum`: stars form a frequency rainbow; you can *see* which register is
  active by which colours surge.
- `drift`: the whole field slowly cycles hue, offset per band.
- `thermal`: quiet stars are embers, loud bands burn white.
- `mono` / `accent` / `ember`: brightness does the talking.

Resolve colours once per band per frame (32 lookups), not per star (500).

### Accessibility

- `reduceMotion`: positions frozen (no advancement, no respawn, no warp
  streaks); only opacity twinkle at one-third amplitude and band-driven
  brightness remain. A still star chart that gently glows with the music.
- `reduceTransparency`: core glow becomes a solid dim disc; star opacity
  floors at 0.6 instead of fading by radius.

## Definitions and contracts

```swift
case starfield             // VisualizerMode; displayName L10n "Starfield"
                           // symbolName "sparkles"
```

```swift
@MainActor
public final class Starfield: Visualizer {
    public init(
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        seed: UInt64? = nil          // nil = SystemRandomNumberGenerator
    )
}
```

Internal state: star pool, previous positions buffer (for streaks),
`warpBoost`, `lastTime`, `lastFrameIndex`, per-band colour cache.

## Implementation plan

1. `VisualizerMode.starfield` + L10n key + pseudolocale; host arm.
2. Star pool + radial motion + respawn + per-band colour cache; circles only.
   Deterministic snapshot via seeded RNG and scripted times.
3. Warp kick envelope + streak rendering + previous-position buffer.
4. Twinkle, fade-in, core glow; reduceMotion / reduceTransparency paths.
5. Perf pass: confirm 60 fps with 500 stars under `drawingGroup()` on M1;
   document measured frame time in the PR.

## Context7 lookups

- `use context7 SwiftUI Canvas drawingGroup many shapes performance`
- `use context7 Swift SystemRandomNumberGenerator seedable RNG SplitMix64`
- `use context7 exponential decay envelope frame rate independent`

## Dependencies

None new. (Seedable RNG is a 10-line SplitMix64, not a package.)

## Test plan

- **Determinism**: same seed + same scripted (analysis, time) sequence renders
  identical snapshots twice.
- **Motion scaling**: with all bands 0 and rms 0, mean radial speed equals the
  base; with `bands[5] = 1`, stars on band 5 move measurably faster than band
  20's stars.
- **Respawn**: after enough scripted frames, no star has radius > 1.1 and the
  pool size is still 500.
- **Warp envelope**: onset sets boost to 2.0; after 0.4 s it is within 5% of
  2.0/e; two onsets 0.1 s apart re-trigger to 2.0, not 4.0 (clamp, no
  stacking).
- **Streak threshold**: boost 0.6 renders lines; 0.4 renders circles.
- **reduceMotion**: positions identical across 100 scripted frames.
- **Colour cache**: `PaletteResolver.color` invoked at most 32 + constant
  times per frame (assert via injected counter in tests).
- **Snapshots**: one seeded mid-track scene across all six palettes; streak
  variant; reduceMotion and reduceTransparency variants on one palette.
- **Long-run**: 10k frames headless, zero heap growth after warm-up.

## Acceptance criteria

- [ ] `starfield` selectable, localized, pseudolocale green.
- [ ] All colour through `PaletteResolver` with per-band caching.
- [ ] Warp streaks fire from real onsets (verify live with percussive music).
- [ ] 60 fps sustained with 500 stars on M1 (auto-simplify never triggers on
      the reference machine).
- [ ] reduceMotion and reduceTransparency behave as specified.
- [ ] Snapshot + unit tests as listed; `make lint && make test-ui` green.
- [ ] No per-frame heap allocation in steady state.

## Gotchas

- **Pool, never append.** Respawn mutates the existing struct in place;
  `append`/`removeAll` per frame fragments and allocates.
- **Streaks need *previous* positions**, not velocity reconstruction; keep a
  parallel buffer and swap, or fast direction changes draw wrong-way streaks.
- **Frame-rate independence.** Both the motion integral and the warp decay
  must use `dt`, not per-frame constants, or 30 fps battery mode plays at
  half speed. The decay is `boost *= exp(-dt / 0.4)`.
- **Onset edge detection.** Consume each onset exactly once using
  `frameIndex`; rendering at 60 Hz against 43 Hz analysis means the same
  onset-flagged `Analysis` is seen by more than one render.
- **`drawingGroup()` and opacity.** Sub-pixel circles with low opacity can
  shimmer under Metal rasterisation; keep minimum star size at 0.8 pt and
  minimum drawn opacity at 0.05.
- **Don't colour per star.** 500 resolver calls per frame is 15x the work of
  32 and `drift` makes each one non-trivial; the per-band cache is mandatory,
  not an optimisation.

## Handoff

Phase 12.5 (Nebula) reuses: the onset-envelope pattern (attack/decay uniform),
the seeded-determinism testing approach, and the per-band-to-group energy
reduction when packing shader uniforms.
