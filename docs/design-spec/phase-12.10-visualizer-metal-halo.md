# Phase 12.10: Metal Halo (CPU Geometry, GPU Rasterisation)

> Prerequisites: Phases 12.6, 12.7 (PolylineRibbon patterns), 12.9
> (instanced-SDF pattern) complete.
>
> Read `docs/design-spec/_standards.md` first, then
> `phase-12.2-visualizer-halo.md` for the original design.

## Goal

Convert Halo to Metal. This is the hardest conversion because the membrane is
variable CPU geometry (Catmull-Rom through 64 audio-driven tips), and the
honest framing is: **the CPU keeps doing the math it does today; the win is
skipping SwiftUI Canvas, Core Graphics path stroking, and the `drawingGroup`
compositing pass.** Expect a real but modest improvement, mostly in
fullscreen Retina latency.

**Mandatory architecture: composition, not duplication.** The existing `Halo`
class already owns the tested state machine (EMA smoothing, rotation,
breathing, tip computation, ripple pool, onset spawning). `MetalHalo` holds a
`Halo` instance and calls its internal methods (`updateSmoothing`,
`updateRotation`, `computeTips`, `spawnRipple`, `expireStaleRipples`, plus
the `rotationPhase` / `rmsEMA` / `smoothedBands` / `ripplePool` properties,
all already `internal` for testing). Copy-pasting that math into `MetalHalo`
is a spec violation: two implementations of the same numbers always drift.

## Non-goals

- No visual changes (breathing depth, rotation speed, ripple lifetime,
  per-spoke colours: all contract, all already encoded in `Halo`).
- No GPU tessellation. The curve sampling stays on the CPU; tessellation
  shaders are a complexity cliff this mode does not need.
- No removal of `Halo.swift` (it is the fallback AND the state machine).

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/Metal/
└── MetalHalo.swift                  # NEW (composes Halo for state)

Modules/UI/Sources/UI/Resources/Shaders/
└── Halo.metal                       # NEW

MetalVisualizerFactory                # + .halo arm
```

## Behavioural contract

Everything `Halo.render` does, in the same order, with the same numbers. The
authoritative source is `Halo.swift` itself; the summary:

1. dt = clamped `time - lastTime` (0...0.1 s); EMA smoothing every frame;
   rotation only when not reduceMotion.
2. Geometry frame: `baseRadius = 0.32 * minDim`, `extent = 0.18 * minDim`,
   `breathingRadius = baseRadius * (1 + 0.06 * (rmsEMA * 2 - 1))`.
3. Onset (not reduceMotion): spawn ripple at `breathingRadius + extent`.
4. Membrane fill: closed Catmull-Rom path through the 64 tips, filled with
   `PaletteResolver.color(position: 0.5, magnitude: rmsEMA)` at opacity 0.25
   (1.0 under reduceTransparency).
5. Rim: per-segment one-band-colour strokes, 2 pt, 64 segments, band colours
   resolved once per band (32 calls) and shared by mirrored spokes.
6. Ripples: up to 6, radius interpolating spawnRadius to `1.2 * minDim` over
   1.2 s, opacity `0.5 * (1 - progress)`, line width `3 - 2 * progress` pt.
7. Centre glow: radial gradient from
   `PaletteResolver.color(position: 0.5, magnitude: bassEnergy)` at alpha
   `bassEnergy` to clear, radius = breathingRadius; solid disc under
   reduceTransparency; skipped entirely when `bassEnergy == 0`.

## Metal design

### CPU `update` (per frame)

1. Drive the composed `Halo` state exactly as `Halo.render` does (smoothing,
   rotation, ripple spawn/expire) but with `MetalHalo` owning the dt clamp
   and `lastTime` so the state machine is stepped once per frame.
2. `tips = core.computeTips(...)` in pixel space.
3. **Curve sampling**: for each of the 64 segments, evaluate the cubic
   Bezier (same control-point construction as `buildCatmullRomPath`:
   `ctrl1 = curr + (next - prev) / 6`, `ctrl2 = next - (afterNext - curr) / 6`)
   at 8 parameter steps, yielding a closed loop of 512 points.
4. **Membrane fill**: triangle fan around the centre point over the 512-point
   loop (the membrane is star-shaped around the centre because every tip
   radius is at least breathingRadius > 0, so the fan is always valid; assert
   this assumption in a code comment). 514 vertices into the FrameRing slot,
   uniform fill colour.
5. **Rim**: one closed ribbon via
   `PolylineRibbon.strip(points: loop512, width: 2 * pixelsPerPoint,
   closed: true)` with a parallel per-vertex colour array: vertices belonging
   to segment s take the colour of band `s % 32`. Interleave position+colour
   into the vertex struct (`SIMD2<Float>` pos + `SIMD4<Float>` color = 32
   bytes per vertex with padding; assert stride).
6. **Ripples + glow**: instanced SDF quads (the 12.9 pattern): up to 6 ring
   instances (centre, radius, ringWidth, colour+alpha) and 1 glow instance
   (centre, radius, colour, gradientFlag). A ring SDF is
   `abs(length(p - c) - radius) - halfWidth`; the glow fragment uses
   `1 - smoothstep(0, radius, length(p - c))` for the radial gradient, or
   flat colour when reduceTransparency.

### Draw order (matches Canvas)

fill fan, rim ribbon, ripples, centre glow. Alpha blending on for all four.

### Pipelines

Two: one position+colour pipeline (fan + ribbon share it; the fan passes the
fill colour as per-vertex colour), one instanced-SDF pipeline (ripples +
glow share it with a shape flag). Both from one `Halo.metal` file.

## reduceMotion / reduceTransparency

Both are already implemented inside the composed `Halo` state machine and the
contract list above; `MetalHalo` only needs to honour them in the same
places (no rotation step, no ripple spawn, slower EMA come free from `core`;
fill opacity and glow style are uniforms set per the flags).

## Implementation plan

1. `MetalHalo` skeleton composing `Halo`; membrane fan + rim ribbon with
   per-vertex colour; static snapshot vs Canvas. Commit.
2. Ripple + glow instanced SDFs; onset wiring. Commit.
3. a11y paths + full snapshot suite + factory arm + live parity check
   (side-by-side screen recording in the PR, since motion smoothness is the
   point of the exercise). Commit.

## Context7 lookups

- `use context7 cubic bezier evaluation parameter sampling`
- `use context7 Metal per vertex color interleaved buffer triangle strip`
- `use context7 ring annulus SDF fragment shader antialiasing`

## Test plan

CPU-side:

- **No math duplication**: a source-convention test (the module's established
  pattern) asserts `MetalHalo.swift` contains no Catmull-Rom control-point
  arithmetic of its own beyond the Bezier *evaluation* (e.g. assert the file
  references `core.computeTips` and does not define `breathingRadius`
  constants; keep the assertion pragmatic).
- **Bezier sampling**: t = 0 yields `curr`, t = 1 yields `next`; midpoints of
  a straight-line segment lie on the line.
- **Fan validity**: with all bands at 1.0 and rotation at an awkward phase,
  every loop point's distance from centre exceeds 1 pt (star-shape guard).
- **Vertex budget**: per frame exactly 514 fan vertices + (512 * 2 + 2)
  ribbon vertices; FrameRing slot sized once at init, no per-frame
  allocation (reuse preallocated arrays).
- **State delegation**: after 60 `update` calls with a fixed analysis,
  `core.rmsEMA` equals the value 60 direct `updateSmoothing` calls produce
  (proves the state machine is stepped once per frame, not zero or twice).
- **Stride assertions** for both vertex structs and the SDF instance struct.

GPU (local-only):

- **Snapshots**: the existing `HaloSnapshotTests` fixture (sine-shaped bands,
  rms 0.6) across all six palettes at 400 x 400, pre-warmed 60 frames, fixed
  time 1000; reduceMotion and reduceTransparency variants. Compare against
  the Canvas references by eye and note the verdict in the PR.

## Acceptance criteria

- [ ] Halo renders via Metal; `visualizer.forceCanvas` flips back live.
- [ ] `MetalHalo` contains zero duplicated Halo state math (composition
      verified by test).
- [ ] Side-by-side parity confirmed in the PR (static snapshots + a motion
      note).
- [ ] No per-frame heap allocation in steady state (preallocated arrays,
      FrameRing).
- [ ] Canvas `Halo` and all its suites untouched and green.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- **The fan centre vertex needs the fill colour too**; a zero-alpha centre
  vertex gradient-fades the membrane towards the middle, which looks
  intentional and is wrong.
- **Closed-ribbon seam**: `PolylineRibbon(closed: true)` repeats the first
  vertex pair; the per-vertex colour array must repeat the first colour pair
  as well or the seam flashes the wrong band colour.
- **Ripple expiry mutates during iteration** in the Canvas version
  (`drawRipples` deactivates expired ripples as it draws). Keep calling
  `core.expireStaleRipples(at:)` before building instances so the pool state
  stays identical to the Canvas timeline; do not re-implement expiry.
- **`PaletteResolver.color` call budget**: 32 band colours + fill + glow +
  ripple-spawn colour. Resolving per vertex (1000+ calls with drift's hue
  math) tanks the frame; resolve into a 32-entry array first, exactly like
  `resolveBandColors`.
- **Degenerate canvas**: a 0-height pane during window animation produces
  minDim 0; guard and skip the frame (Canvas survives this implicitly via
  Path no-ops; Metal NaNs propagate into vertices and the validation layer
  screams).

## Handoff

12.11 (Starfield) reuses the instanced-SDF pipeline shape at 500 instances
and the per-band colour-array uniform idea.
