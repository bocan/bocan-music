# Phase 12.5: Visualizer Mode "Nebula" (Metal Gas Clouds + Moving Wisps)

> **Plumbing superseded.** Implement this mode via
> `phase-12.12-visualizer-metal-nebula.md`, which lands it on the shared
> Metal foundations from phase 12.6. The visual design, audio mapping, test
> plan, and gotchas below remain binding; the bespoke NebulaMetalView and
> NebulaRenderer plumbing does not.
>
> Prerequisites: Phase 12.1 complete (Analysis v2, `PaletteResolver.rampStops`,
> `render(... time:)`). Phases 12.2 to 12.4 are independent but land first;
> this is the most ambitious mode and finally delivers the Metal mode that
> phase 12 specified as "Fluid" and never shipped.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Swirling clouds of luminous gas that move *with* the music: bass energy stirs
the turbulence, four glowing wisps drift through the field on orbits that speed
up with the mids, onsets send a pressure wave through the gas, and the colour
ramp comes from the user's palette. In silence the nebula hangs almost still,
barely breathing; this is the proof that it taps the real stream rather than
playing a canned loop.

Implemented as a full-screen Metal fragment shader (domain-warped fractal
noise), not a particle system. There is no per-frame simulation state on the
GPU; everything the shader needs arrives as uniforms computed on the CPU from
`Analysis`, which keeps the CPU side fully unit-testable.

## Non-goals

- No Navier-Stokes fluid sim, no compute-pass advection; domain-warped fBm
  gives the gas look at a fraction of the cost and with zero stateful risk.
- No shader plugin system (still phase 12's non-goal).
- No per-mode settings; sensitivity, FPS cap, and palette come from the
  existing global settings.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── VisualizerMode.swift             # + case nebula
├── VisualizerHost.swift             # + Metal branch (see below)
└── Metal/
    ├── NebulaMetalView.swift        # NSViewRepresentable wrapping MTKView
    ├── NebulaRenderer.swift         # MTKViewDelegate; uniforms, LUT, pacing
    ├── NebulaUniforms.swift         # CPU-side uniform packing (testable)
    └── Nebula.metal                 # the shader
```

## Visual design

### The gas

Classic Inigo Quilez domain warping in the fragment shader:

```
q = fbm(p * 1.8 + flowTime * dir1)
r = fbm(p * 1.8 + 4.0 * q + flowTime * dir2)
d = fbm(p * 1.8 + 4.0 * r)          // density 0...1
```

4-octave value-noise fBm; three nested evaluations per pixel. `p` is the
aspect-corrected UV. The key audio hook is **flowTime**: it is not wall time
but an integral accumulated on the CPU each frame:

```
flowTime += dt * (0.02 + 0.30 * bassEnergy + onsetEnvelope * 0.5)
```

Heavy bass literally makes the gas churn faster; silence slows it to a near
standstill (0.02 baseline keeps it alive). The warp amplitude (the `4.0`
factors) is modulated `+/- 25%` by `midEnergy`, so dense mixes visibly knot
the clouds.

### The wisps (moving shapes)

Four bright shapes drifting through the gas, one per band group (bass, low
mids, high mids, treble). CPU-side, each wisp's position follows a Lissajous
orbit driven by `flowTime` (so orbital speed also follows the music):

```
pos_i = centre + amp_i * (sin(a_i * flowTime + phi_i),
                          sin(b_i * flowTime + psi_i))
```

with co-prime-ish frequency pairs per wisp so paths never visibly repeat.
In the shader each wisp contributes:

- a Gaussian density blob, strength = its band group's energy (a silent group's
  wisp fades out entirely), radius breathing with that energy;
- a local **swirl**: rotation of the warp domain around the wisp position,
  falling off with distance, so gas visibly spirals around each shape.

### Onsets

`onsetEnvelope` (attack to 1.0 on onset, exponential decay tau 0.3 s, clamped,
no stacking; same pattern as Starfield's warp kick) is a uniform that:

- briefly boosts exposure (brightness curve) by up to 20%;
- adds a radial displacement pulse centred on the loudest wisp, reading as a
  pressure wave rippling through the gas.

### Colour (the current method)

The shader maps density through a 256 x 1 RGBA texture LUT generated CPU-side
from `PaletteResolver.rampStops(palette:analysis:time:)`, exactly the Cascade
LUT idea promoted to a texture:

- static palettes: LUT built once;
- `drift`: LUT regenerated when the base hue moves more than 1/256 cycle
  (a few times per second; a 1 KB texture upload, negligible);
- `thermal` over the density field is the showpiece combination;
- hue position within the ramp is additionally offset by `centroid * 0.15`
  so trebly passages tint the whole nebula.

No colour decisions live in the shader beyond sampling the LUT.

### Accessibility

- `reduceMotion`: the mode is unavailable, exactly as phase 12 specified for
  the fluid mode. `VisualizerHost` substitutes `SpectrumBars` (calm style) when
  `reduceMotion && mode == .nebula`; the Settings picker disables the Nebula
  option with an explanatory `.help` tooltip (localized).
- `reduceTransparency`: the shader output is already opaque over black; ensure
  no dependence on layer blending (composite everything in the shader).

## Integration contracts

```swift
case nebula                // VisualizerMode; displayName L10n "Nebula"
                           // symbolName "hurricane"
```

### VisualizerHost branch

The `Visualizer` protocol is `GraphicsContext`-based and does not fit Metal;
do not force it. `VisualizerHost.body` branches:

- Canvas modes: existing `timelineCanvas` path, unchanged.
- `.nebula` (and reduceMotion off): `NebulaMetalView(vm: vm)` in the same
  `ZStack`, same toast overlay, same accessibility label plumbing.

### Frame pacing and auto-simplify

- `MTKView.preferredFramesPerSecond = vm.effectiveFPS`; re-applied when the
  setting changes.
- The Metal path must feed the same watchdog that Canvas modes get from
  `recordFrameTick`. `NebulaMetalView` invokes an `onFrame: (Date) -> Void`
  callback per draw, wired to the host's existing `recordFrameTick`, so a
  sustained sub-30 fps Nebula auto-switches to Spectrum Bars with the existing
  toast and Revert button. This is the mode auto-simplify exists for.
- **Adaptive render scale before giving up**: the renderer draws at
  0.6 x drawable resolution by default (the gas is soft; nobody can tell) and
  drops to 0.4 x if its own rolling frame time exceeds budget, logging
  `visualizer.nebula.scale.reduced`. Only if 0.4 x still cannot hold 30 fps
  does auto-simplify fire.
- First-frame warm-up (phase 12 gotcha): the view stays at alpha 0 over the
  black host background until the first drawable presents, then fades in over
  150 ms. No placeholder spinner.

### Fullscreen

`FullscreenWindow` reuses `VisualizerHost`, so Nebula works there with no
extra code; the pane and fullscreen window may each own an `MTKView`
simultaneously (the view model's tap is already reference-counted).

## Implementation plan

1. `VisualizerMode.nebula` + L10n keys (name + disabled-tooltip) +
   pseudolocale; host branch rendering a solid colour via Metal (plumbing
   proof). Commit.
2. `NebulaUniforms` packing: band-group energies, flowTime integration,
   onset envelope, wisp orbits, render scale; pure functions plus a small
   stateful accumulator struct, fully unit-tested. Commit.
3. Shader: fBm + domain warp + LUT sampling; static LUT palettes working.
4. Wisps (blobs + swirl) and onset pressure wave.
5. Drift LUT regeneration; centroid tint.
6. Pacing: preferredFramesPerSecond wiring, onFrame watchdog, adaptive scale,
   warm-up fade.
7. reduceMotion fallback + disabled picker option; settings snapshot.
8. Perf validation on M1 (see test plan); document measured numbers in the PR.

## Context7 lookups

- `use context7 MTKView NSViewRepresentable SwiftUI macOS`
- `use context7 SwiftPM metal shader resource default.metallib Bundle.module`
- `use context7 Inigo Quilez domain warping fbm`
- `use context7 MTKView preferredFramesPerSecond drawableSize render scale`
- `use context7 Metal fragment shader texture 1D lookup table`

## Dependencies

None new; `Metal` and `MetalKit` are system frameworks (already anticipated by
phase 12). Verify SwiftPM compiles `Nebula.metal` into the module's
`default.metallib` (Swift 5.3+ behaviour); if the toolchain disappoints, fall
back to runtime compilation from a Swift string constant and document it.

## Test plan

CPU side (the coverage target; the GPU pass is exempt, as phase 12 already
established for Metal render paths and must be documented the same way):

- **flowTime**: integrating 1 s of silence advances flowTime by 0.02; 1 s of
  `bassEnergy = 1.0` advances it by 0.32; never decreases.
- **Onset envelope**: identical contract to Starfield's (attack 1.0, tau
  0.3 s, no stacking); shared test shape.
- **Wisp orbits**: deterministic for a given flowTime; positions stay within
  the unit rectangle; a zero-energy group's strength uniform is 0.
- **Uniform packing**: a scripted `Analysis` sequence produces a golden
  uniform buffer (struct equality, no NaN, all values in documented ranges).
- **LUT**: per-palette first/last texel match `rampStops`; drift regeneration
  threshold honoured; static palettes never regenerate.
- **Render scale**: scripted slow frame times step 0.6 to 0.4; recovery does
  not oscillate (hysteresis).
- **Watchdog wiring**: scripted `onFrame` dates below 30 fps for 3 s trigger
  `autoSimplify` exactly once (reuses the host test approach).
- **reduceMotion**: host renders SpectrumBars when mode is nebula; picker
  option disabled; snapshot of settings in that state.
- **Smoke render** (skipped automatically when no Metal device, e.g. exotic
  CI): one offscreen 256 x 256 frame completes without error and is not all
  black for a non-silent uniform set.

Manual verification (note in PR): play a bass-heavy track, confirm churn
follows the kick; pause and confirm near-stillness within about 2 s.

## Acceptance criteria

- [ ] `nebula` selectable, localized, pseudolocale green.
- [ ] Gas motion, wisp speed, brightness, and pressure waves all derive from
      the live tap (silence test passes).
- [ ] All colour through `PaletteResolver.rampStops`; six palettes render.
- [ ] 60 fps at 0.6 x scale on M1 built-in display in fullscreen.
- [ ] Auto-simplify and adaptive scale verified via scripted tests.
- [ ] reduceMotion fallback and disabled picker option work.
- [ ] CPU-side analysis/uniform path at 80%+ coverage; GPU pass documented
      exempt.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- **SwiftPM Metal compilation is the build risk.** Prove `Bundle.module`
  yields a `default.metallib` in step 1 before writing any shader of
  substance; the runtime-compile fallback changes error handling.
- **Three nested fBm calls are about 12 noise evaluations per pixel.** At
  native 5K fullscreen that is too hot for integrated GPUs; the 0.6 x render
  scale is part of the design, not an optimisation to add later.
- **`MTKView` lifecycle in SwiftUI.** Dismantle must stop the draw loop
  (`isPaused = true`, delegate nil) or the GPU keeps drawing for a closed
  pane; verify with the fullscreen open/close test from phase 12.
- **Uniform struct layout.** Match Swift and MSL layouts explicitly
  (`MemoryLayout` assertions in tests); a silent misalignment shows up as
  "wisps ignore the music", which looks like a design bug, not a memory bug.
- **Two simultaneous MTKViews** (pane + fullscreen) double GPU cost; that is
  accepted, but the adaptive scale must be per-renderer, not global.
- **Battery**: `effectiveFPS` already caps to 30 on battery; do not add a
  second battery heuristic in the renderer.
- **Hue discontinuity in drift.** Regenerating the LUT shifts all colours at
  once; with the gas's soft gradients this reads as a gentle global tint
  change, which is fine, but never lerp the LUT *during* a frame.
- **`AVAudioTime` and sample rate changes** do not matter here; everything
  flows through `Analysis`. Resist reading the tap directly from the renderer.

## Handoff

This completes the six-mode set (Bars, Oscilloscope, Halo, Cascade, Starfield,
Nebula). Follow-ups that become possible afterwards: README and website
feature pages for the visualizer suite (required by the repo's commit
conventions when these ship), and revisiting phase 12's unchecked long-run
memory acceptance box with all six modes in the soak test.
