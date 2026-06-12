# Phase 12.2: Visualizer Mode "Halo" (Radial Spectrum + Beat Ripples)

> Prerequisites: Phase 12.1 complete (Analysis v2, `PaletteResolver`,
> `render(... time:)`).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A circular spectrum visualizer: the 32 bands wrap around a ring as a smooth,
organically pulsing closed shape, the whole ring slowly rotates with the music,
and detected onsets launch expanding ripple rings. It reads as a living halo of
sound rather than a bar chart bent into a circle.

Canvas-based, cheap, and the visual opposite of the rectilinear Spectrum Bars.

## Non-goals

- No 3D, no Metal; this is a pure `Canvas` mode.
- No album-art integration in the centre (possible later polish).
- No user-tunable geometry; one curated look.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── Halo.swift                       # NEW: the renderer
├── VisualizerMode.swift             # + case halo
└── VisualizerHost.swift             # + rebuildRenderer arm
```

## Visual design

- **The ring.** The 32 bands are mirrored into 64 spokes (band 0 at angle 0
  and angle 180 degrees, sweeping symmetrically) so the shape is balanced.
  Spoke radius = `baseRadius + band * extent`, where `baseRadius` is
  0.32 of `min(width, height)` and `extent` is 0.18 of the same. The 64 tips
  are joined into a single closed path via Catmull-Rom-to-Bezier smoothing,
  filled at 25% opacity and stroked at full opacity, so the halo looks like a
  membrane, not spokes.
- **Breathing.** `baseRadius` is modulated plus or minus 6% by the smoothed RMS,
  so the whole halo inhales with the track's loudness.
- **Rotation.** The ring rotates at `0.02 + 0.08 * trebleEnergy` revolutions
  per second. Quiet, dark passages nearly still; bright cymbal-heavy passages
  visibly spin. Rotation accumulates via `dt` from the injected `time` so it
  never jumps when FPS changes.
- **Beat ripples.** On `analysis.onset`, spawn a circle at the current outer
  radius that expands to 1.2 times `min(width, height)` over 1.2 s while its
  opacity falls 0.5 to 0 and stroke width 3 to 1. Fixed pool of 6 ripples;
  a 7th onset recycles the oldest. Pool slots are structs in a fixed array;
  zero per-frame allocation.
- **Centre glow.** A radial gradient disc inside the ring whose alpha tracks
  `bassEnergy` (kick drums glow from within).

### Colour (the current method)

Everything resolves through `PaletteResolver`:

- Spokes: `position = bandIndex / 31` (both mirrored copies share the band's
  colour), `magnitude = band value`.
- Ring stroke: gradient along the path from the per-spoke colours.
- Ripples: `position = 0`, `magnitude = bassEnergy` at spawn time, colour
  frozen for the ripple's lifetime.
- Centre glow: `position = 0.5`, `magnitude = bassEnergy`.

All six palettes (including `drift` and `thermal`) work with no Halo-specific
colour code.

### Accessibility

- `reduceMotion`: rotation off, ripples off, breathing off; the ring still
  follows the bands but through a heavier smoothing pass (visual release about
  3 times slower). This matches the calm-still-life convention from phase 12.
- `reduceTransparency`: membrane fill and centre glow become fully opaque solid
  fills; no gradient alpha.
- Accessibility label comes free via `VisualizerHost` ("Visualizer: Halo").

## Definitions and contracts

```swift
case halo                  // VisualizerMode; displayName L10n "Halo"
                           // symbolName "circle.circle"
```

```swift
@MainActor
public final class Halo: Visualizer {
    public init(
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool
    )
}
```

Internal state: rotation phase, smoothed band copy, RMS EMA, ripple pool
(fixed-size array of `struct Ripple { birth: TimeInterval; color: Color }`),
`lastTime` for `dt` (clamped 0...0.1 s).

## Implementation plan

1. `VisualizerMode.halo` + L10n key + `make pseudolocale`; `rebuildRenderer`
   arm in `VisualizerHost`. Commit (renders nothing yet behind the new case is
   fine only within the same PR; land the full renderer before merging).
2. Ring geometry: mirrored spokes, Catmull-Rom smoothing, fill + stroke,
   breathing. Snapshot test with a fixed `Analysis`.
3. Rotation + `dt` handling; ripple pool driven by `analysis.onset`;
   centre glow.
4. `reduceMotion` / `reduceTransparency` paths + snapshot variants.
5. Settings picker picks the mode up automatically via `CaseIterable`;
   verify settings snapshot.

## Context7 lookups

- `use context7 Catmull-Rom to cubic Bezier closed path`
- `use context7 SwiftUI Canvas gradient stroke along path`
- `use context7 SwiftUI Canvas radial gradient GraphicsContext`

## Dependencies

None new.

## Test plan

- **Geometry**: with all bands 0, the path is a circle of `baseRadius` (64 tip
  radii equal within epsilon). With band k = 1.0, exactly the two mirrored
  spokes for k extend by `extent`.
- **Rotation determinism**: two renders at times t and t + 1 s with
  `trebleEnergy = 0` differ by exactly 0.02 revolutions of phase.
- **Ripples**: an onset frame appends one ripple; 7 onsets leave pool size 6
  with the oldest recycled; a ripple older than 1.2 s is not drawn.
- **reduceMotion**: rotation phase and ripple pool never change across frames.
- **Snapshots**: fixed `Analysis` (a recognisable band pattern) across all six
  palettes at one size, plus reduceMotion and reduceTransparency variants on
  one palette.
- **Perf sanity**: render 1000 frames headless under 1 ms average on M1
  (one path, up to 6 circles, one gradient; this is the cheapest new mode).

## Acceptance criteria

- [ ] `halo` selectable in Settings and via the host; localized; pseudolocale green.
- [ ] All colour through `PaletteResolver`; all six palettes render.
- [ ] Onset ripples fire from real tap analysis (verify live with percussive music).
- [ ] reduceMotion and reduceTransparency behave as specified.
- [ ] Snapshot + unit tests as listed; `make lint && make test-ui` green.
- [ ] No per-frame heap allocation in steady state (ripple pool is fixed).

## Gotchas

- **Catmull-Rom at the seam.** Closing the loop needs wraparound control
  points (indices mod 64) or the seam shows a visible kink at angle 0.
- **Mirroring is by band, not by angle.** Position passed to the resolver must
  be the band fraction, or the spectrum palette renders two full rainbows and
  the mirror symmetry reads as an error.
- **Clamp `dt`.** TimelineView pauses (window hidden, fullscreen transitions)
  produce huge deltas; an unclamped ripple pool or rotation jump looks like a
  glitch.
- **Onset edge, not level.** `analysis.onset` is already edge-triggered per
  frame upstream; do not add a second debounce here or fast double-kicks lose
  their second ripple.
- **Gradient stroke cost.** Stroking with a 64-stop angular gradient every
  frame is more expensive than it looks; build the `Gradient` only when the
  palette inputs change beyond a threshold (always rebuild for drift, since it
  moves; it is one allocation per frame at most, measure first).

## Handoff

Phase 12.3 (Cascade) is independent. The ripple-pool pattern (fixed-size
struct pool keyed on birth time) is reused by Starfield (12.4) for its warp
streaks; keep it simple and copyable.
