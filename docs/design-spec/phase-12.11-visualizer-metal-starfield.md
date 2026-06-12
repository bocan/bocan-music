# Phase 12.11: Starfield on Metal (New Mode, Supersedes 12.4's Renderer)

> Prerequisites: Phases 12.6 (foundations, `OnsetEnvelope`), 12.9
> (instanced-SDF pattern) complete.
>
> **This phase supersedes the rendering technology of
> `phase-12.4-visualizer-starfield.md`. Do not implement the Canvas Starfield
> first.** Everything in 12.4 about visual design, motion, accessibility, and
> behaviour remains binding; only its "Canvas plus drawingGroup, no Metal"
> outcome shape and its renderer-specific test items are replaced by this
> document. Where the two documents conflict, this one wins.
>
> Read `docs/design-spec/_standards.md` and `phase-12.4-visualizer-starfield.md`
> first.

## Goal

Implement the Starfield mode (frequency-coloured warp field, 500 stars, warp
kicks on onsets) directly as a `MetalVisualizer`. Unlike 12.7 to 12.10 there
is no Canvas twin: Starfield is the first Metal-only mode, which makes it the
phase that introduces the "mode requires Metal" machinery that Nebula (12.12)
also needs.

## Non-goals

- Everything 12.4 lists (no 3D projection, no particle interaction), plus:
- No Canvas fallback renderer for this mode. On a Metal-less machine the
  mode is unavailable (machinery below); do not write a second renderer.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── VisualizerMode.swift             # + case starfield (+ requiresMetal)
└── Metal/
    ├── StarfieldCore.swift          # NEW: simulation (no Metal imports)
    └── MetalStarfield.swift         # NEW: renderer (thin)

Modules/UI/Sources/UI/Resources/Shaders/
└── Starfield.metal                  # NEW

MetalVisualizerFactory                # + .starfield arm
VisualizerSettingsView                # disabled state for Metal-less machines
```

## Mode availability machinery (new in this phase, reused by 12.12)

```swift
public extension VisualizerMode {
    /// Modes with no Canvas renderer. Selectable only when a Metal device
    /// exists; the host substitutes SpectrumBars otherwise.
    var requiresMetal: Bool { self == .starfield }   // 12.12 adds .nebula
}
```

- `VisualizerHost.rebuildRenderer()`: when `mode.requiresMetal` and the
  factory returns nil (no device or init failure), build
  `SpectrumBars(palette:reduceMotion:reduceTransparency:)` as the renderer
  and log `visualizer.metal.required.fallback` once (mode + reason).
- `VisualizerSettingsView` mode picker: options where
  `mode.requiresMetal && MetalSupport.device == nil` are `.disabled` with a
  localized `.help` tooltip. New L10n keys (run `make pseudolocale`):
  - `"Starfield"` (the mode displayName; symbolName `"sparkles"`)
  - `"Requires Metal graphics support, which this Mac does not provide."`
    (shared tooltip key; 12.12 reuses it)

## Behavioural contract (from 12.4, restated where load-bearing)

- 500 stars, preallocated `ContiguousArray<Star>` (angle, radius 0...1.1,
  size 0.8...2.4 pt, bandIndex 0...31 uniform, twinklePhase), seeded RNG
  (`init(seed: UInt64?)`, SplitMix64, nil = random) for deterministic tests.
- Motion per frame, dt clamped 0...0.1 s:
  `speed = 0.05 + 0.5 * rms + 0.7 * bands[bandIndex] + warpBoost`;
  `radius += dt * speed * (0.3 + radius)`; respawn past 1.1 at radius 0.02
  with fresh random angle.
- Warp kick: `warpBoost = 2.0 * onsetEnvelope.value` with
  `OnsetEnvelope(tau: 0.4)` (the 12.6 helper; onset edge-detection via
  frameIndex comes with it). Streak rendering while `warpBoost > 0.5`: a
  line from the previous frame position to the current one, width = star
  size; circles of radius `size * (0.6 + 0.6 * bands[bandIndex])` otherwise.
- Twinkle: `opacity = fadeIn(radius) * (0.85 + 0.15 * sin(3 * time +
  twinklePhase))`; `fadeIn` ramps 0 to 1 over radius 0...0.15.
- Core glow: centre radial gradient, alpha follows `bassEnergy`.
- Colour: `PaletteResolver.color(position: bandIndex / 31,
  magnitude: bands[bandIndex])`, resolved into a 32-entry array per frame
  (never per star).
- reduceMotion: positions frozen (no advancement, respawn, or streaks);
  twinkle at one-third amplitude; band-driven brightness stays.
- reduceTransparency: core glow becomes a solid dim disc; star opacity
  floors at 0.6.

## Metal design

### `StarfieldCore` (the testable 80%)

A plain Swift type, no Metal imports, owning: the star pool, previous
positions buffer, RNG, `OnsetEnvelope`, and
`step(analysis:time:) -> Void` plus
`instances(drawableSize:pixelsPerPoint:) -> [StarInstance]` (writes into a
caller-provided buffer pointer in production; returns an array under a test
seam). All 12.4 motion/respawn/twinkle/warp rules live here. This split is
what keeps the module coverage floor satisfiable.

### Instance data (one struct, assert stride 48)

```swift
struct StarInstance {
    var endA: SIMD2<Float>       // pixel pos this frame
    var endB: SIMD2<Float>       // pixel pos previous frame (== endA if circle)
    var color: SIMD4<Float>      // band colour, twinkle+fade premultiplied into alpha
    var radius: Float            // pixels (circle radius or half streak width)
    var pad: SIMD2<Float>
    var pad2: Float
}
```

A circle is a capsule whose endpoints coincide, so **one SDF covers both
shapes**: `sdCapsule(p, endA, endB, radius)`. No shader branch on a mode
flag, no separate pipelines. The core glow is instance 501 with a
gradient flag in `color.a` sign or a dedicated tiny second draw; prefer the
12.9/12.10 shared instanced-SDF pipeline with a shape flag if 12.10 landed
one.

### Per-frame flow

`update`: `core.step`, fill the FrameRing slot with 500 (+glow) instances,
36 colour resolutions (32 bands + glow + spares). `encode`: one instanced
draw of 6-vertex quads sized to each capsule's bounding box (computed in the
vertex shader from endA/endB/radius, padded by 1 px for the AA edge).

## Implementation plan

1. `case starfield` + `requiresMetal` machinery + L10n + pseudolocale +
   settings disabled state + host fallback; mode renders solid black via a
   stub renderer. Commit.
2. `StarfieldCore`: pool, motion, respawn, seeded RNG, full unit tests (no
   GPU). Commit.
3. Capsule shader + instances: circles render; deterministic seeded
   snapshot. Commit.
4. Warp kick + streaks + twinkle + fade-in + core glow. Commit.
5. a11y paths + full snapshot matrix + 10k-frame allocation check. Commit.

## Context7 lookups

- `use context7 capsule SDF segment distance fragment shader`
- `use context7 SplitMix64 seedable random number generator Swift`
- `use context7 Metal instanced quad bounding box vertex shader`

## Test plan

CPU-side (`StarfieldCore`, the bulk):

- All of 12.4's test plan items that concern simulation: determinism under a
  fixed seed, motion scaling with band energy, respawn bounds and constant
  pool size, warp envelope values (delegated to the already-tested
  `OnsetEnvelope`; test the 2.0 scaling and the 0.5 streak threshold here),
  reduceMotion frozen positions over 100 frames, colour-resolution call
  budget (inject a counting resolver seam), zero allocation after warm-up
  (10k steps).
- **Instance mapping**: circle instances have endA == endB; streak instances
  appear only while boost > 0.5; alpha carries twinkle * fadeIn (golden
  values at fixed time/seed).
- **Stride assertion**: 48 bytes.

GPU (local-only):

- **Snapshots**: one seeded mid-track scene across all six palettes; a
  streak-active variant (scripted onset 0.1 s before the snapshot frame);
  reduceMotion and reduceTransparency variants on one palette.

Host/settings:

- Picker disabled state with tooltip when the device is nil (source
  convention test; the live nil-device case cannot run on real hardware).
- Host substitutes SpectrumBars when factory returns nil for a
  requiresMetal mode (unit-testable by forcing the factory via the
  `visualizer.forceCanvas` default plus mode = starfield: define that
  combination as "factory returns nil", i.e. forceCanvas also disables
  Metal-only modes and triggers the same fallback; assert it).

## Acceptance criteria

- [ ] `starfield` selectable, localized, pseudolocale green; disabled with
      tooltip when Metal is absent.
- [ ] All simulation behaviour matches 12.4's contract; its applicable test
      plan items pass.
- [ ] 60 fps sustained with 500 stars on the reference M1 (auto-simplify
      never fires there); note measured frame time in the PR.
- [ ] Warp streaks verified live with percussive material.
- [ ] No per-frame heap allocation in steady state.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- 12.4's pool/streak/frame-rate-independence/onset-edge gotchas all still
  apply; read them.
- **Previous-position buffer and respawn**: a star that respawned this frame
  must have endB reset to its new position, or it draws a full-screen streak
  from its death point. This is the most common visible bug in warp fields.
- **The capsule bounding quad must cover both endpoints plus radius**, in
  the vertex shader, before NDC conversion; clipping a fast streak to one
  endpoint's quad truncates it mid-screen.
- **forceCanvas semantics**: for Canvas-twinned modes it switches renderer;
  for Metal-only modes it must produce the SpectrumBars fallback, not a
  black pane. The test plan pins this.
- **Do not let the settings picker hide the mode entirely** on Metal-less
  machines; disabled-with-tooltip is the contract (discoverability beats
  mystery).

## Handoff

12.12 (Nebula) extends `requiresMetal`, reuses the shared tooltip key, the
`OnsetEnvelope`, and the StarfieldCore-style CPU/GPU split (its uniforms
packer plays the role of the core).
