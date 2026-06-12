# Phase 12.12: Nebula on the Metal Foundations (Delta Over 12.5)

> Prerequisites: Phases 12.6 (foundations), 12.11 (Starfield: `requiresMetal`
> machinery, shared tooltip key, `OnsetEnvelope` in anger) complete.
>
> **This phase is a delta over `phase-12.5-visualizer-nebula.md`.** Phase 12.5
> was written before the shared Metal infrastructure existed and specifies its
> own bespoke plumbing (`NebulaMetalView`, `NebulaRenderer`, its own watchdog
> wiring, its own metallib strategy). All of 12.5's **visual design, audio
> mapping, uniforms philosophy, test plan, and gotchas remain binding**; this
> document replaces only its integration and plumbing sections. Where the two
> conflict, this one wins.
>
> Read `docs/design-spec/_standards.md`, `phase-12.5-visualizer-nebula.md`,
> and `phase-12.6-visualizer-metal-foundations.md` first.

## Goal

Implement Nebula (domain-warped fBm gas, four wisps, onset pressure waves) as
a `MetalVisualizer` on the 12.6 foundations, completing the six-mode set.

## What carries over from 12.5 unchanged

- The entire "Visual design" section: the fBm domain warp, `flowTime`
  integration (`flowTime += dt * (0.02 + 0.30 * bassEnergy +
  onsetEnvelope * 0.5)`), warp amplitude modulated +-25% by `midEnergy`,
  the four Lissajous wisps with per-band-group strength and local swirl, the
  onset exposure boost and pressure wave.
- Colour: density through a 256 x 1 LUT texture from
  `PaletteResolver.rampStops`, centroid tint offset `centroid * 0.15`, drift
  regeneration semantics.
- Accessibility: **mode unavailable under reduceMotion** (host substitutes
  SpectrumBars; settings option disabled with a localized explanatory
  tooltip). reduceTransparency: fully composited in-shader, opaque output.
- The CPU-side test plan (flowTime, envelope, orbits, golden uniform buffer,
  LUT, render scale hysteresis, watchdog, reduceMotion fallback, smoke
  render) and the manual bass-churn verification.
- All gotchas (uniform layout, two simultaneous views, battery, hue
  discontinuity, never reading the tap directly).

## What this delta replaces

| 12.5 said | Now |
|---|---|
| `NebulaMetalView.swift` (bespoke NSViewRepresentable) | Deleted from scope. `MetalVisualizerView` (12.6) hosts it like every other mode. |
| `NebulaRenderer.swift` (bespoke MTKViewDelegate, pacing, watchdog) | `MetalNebula: MetalVisualizer`. Pacing, watchdog ticks, warm-up fade, and teardown all come from the 12.6 host. |
| "Verify SwiftPM compiles Nebula.metal into default.metallib; fall back to runtime compilation if the toolchain disappoints" | Decided in 12.6: runtime compilation via `MetalShaderLibrary`, always. `Nebula.metal` lives in `Resources/Shaders/` like the others. |
| Own onset envelope implementation | `OnsetEnvelope(tau: 0.3)` from 12.6. |
| Own LUT texture code | `PaletteRampLUT.makeTexture` / `upload` from 12.6 (exercised by 12.8). The centroid tint stays a shader-side uniform offset, not a LUT rebuild. |
| `VisualizerHost` gains a special `.nebula` Metal branch | Already generic: factory arm + `requiresMetal` includes `.nebula` (extend the 12.11 property). |
| Own first-frame warm-up fade | 12.6 host behaviour. |
| Adaptive render scale implemented ad hoc | The `renderScale` protocol property (12.6), overridden here: default 0.6, drop to 0.4 when the rolling CPU-side frame budget is exceeded, recover with hysteresis exactly per 12.5's test plan. The 12.6 host re-reads `renderScale` every frame, so no extra wiring. |

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── VisualizerMode.swift             # + case nebula; requiresMetal includes it
└── Metal/
    ├── NebulaUniforms.swift         # NEW: packing + flowTime + orbits (testable)
    └── MetalNebula.swift            # NEW: renderer (thin)

Modules/UI/Sources/UI/Resources/Shaders/
└── Nebula.metal                     # NEW: fBm domain warp + wisps + LUT sample

MetalVisualizerFactory                # + .nebula arm
VisualizerSettingsView                # nebula disabled under reduceMotion
                                      # (reuses the Metal-absent machinery shape)
```

L10n keys (run `make pseudolocale`): `"Nebula"` (displayName; symbolName
`"hurricane"`), plus one new tooltip key for the reduceMotion-disabled state:
`"Unavailable while Reduce Motion is on."` The Metal-absent tooltip is the
shared key from 12.11.

## Availability matrix (implement exactly this)

| Condition | Picker option | Host renders |
|---|---|---|
| Metal absent | disabled, 12.11 tooltip | SpectrumBars fallback |
| reduceMotion on | disabled, new tooltip | SpectrumBars (calm style comes free from its own reduceMotion flag) |
| both | disabled, Metal tooltip wins | SpectrumBars fallback |
| otherwise | enabled | MetalNebula |

Mode-availability changes must also handle the stored `@AppStorage` value:
if `visualizer.mode == nebula` and reduceMotion turns on mid-session, the
host's existing a11y `.onChange` rebuild already re-routes to the fallback;
do not mutate the stored mode (the user gets Nebula back when reduceMotion
turns off).

## Implementation plan

1. `case nebula` + `requiresMetal` + L10n + pseudolocale + picker rules +
   factory arm rendering a flat colour through the foundations (plumbing
   proof). Commit.
2. `NebulaUniforms` packing: flowTime integrator, `OnsetEnvelope`, wisp
   orbits, band-group energies, render-scale state machine; full unit tests
   per 12.5's CPU test plan. Commit.
3. `Nebula.metal`: fBm + domain warp + LUT sampling; static palettes.
   Commit.
4. Wisps (blobs + swirl) + onset pressure wave. Commit.
5. Drift LUT regeneration + centroid tint; render-scale hysteresis live.
   Commit.
6. Snapshot matrix + perf validation on the reference M1 (60 fps at 0.6x
   fullscreen; numbers in the PR). Commit.

## Context7 lookups

12.5's list still applies, minus the SwiftPM metallib item (decided), plus:

- `use context7 Metal fragment shader value noise fbm octaves`
- `use context7 MTKView drawableSize render scale aspect ratio uniform`

## Test plan

12.5's test plan verbatim, with these substitutions:

- "Watchdog wiring" is already covered by 12.6's host tests; keep only a
  source-convention assertion that Nebula goes through the standard factory.
- The onset-envelope contract tests live in 12.6; here test only the tau
  (0.3 s) and its two consumers (exposure boost <= 20%, pressure wave
  centred on the loudest wisp).
- Render-scale hysteresis: scripted frame times step 0.6 to 0.4 and recover
  without oscillation, via the pure state machine in `NebulaUniforms` (no
  GPU).
- Snapshot matrix: scripted uniforms (fixed flowTime, wisp positions,
  envelope) across all six palettes at one size, local-only. Determinism
  note: fix every uniform; never snapshot from live integration.

## Acceptance criteria

12.5's list, re-read it, plus:

- [ ] Zero bespoke MTKView/delegate/pacing code in the Nebula files; the
      diff to `VisualizerHost` is one factory arm and the `requiresMetal`
      extension.
- [ ] Availability matrix implemented exactly, including the
      stored-mode-preserved rule.
- [ ] `make lint && make test-ui && make test-coverage` green; GPU pass
      coverage exemption documented the established way.

## Gotchas

All of 12.5's, plus:

- **Do not let the shader grow CPU opinions.** Every audio-reactive number
  arrives as a uniform from `NebulaUniforms`; if a reviewer finds
  `bassEnergy` math inside the `.metal` file, the testability contract is
  broken.
- **renderScale interacts with aspect correction**: the fragment shader's
  aspect-corrected UV must derive from the *drawable* size uniform, which
  shrinks with the scale; deriving it from the view size stretches the gas
  at 0.4x.
- **The 12.6 host re-reads `renderScale` per frame**; make the property a
  cheap stored value updated inside `update`, not a computed property doing
  the rolling-average math on every read.

## Handoff

The six-mode set is complete (Bars, Oscilloscope, Halo, Cascade, Starfield,
Nebula), all on shared Metal infrastructure with Canvas fallbacks where twins
exist. Required follow-ups per repo conventions: README and website feature
pages for the visualizer suite, and the phase 12 long-run memory soak across
all six modes. Optional future work unlocked: deleting the Canvas twins if
the Metal paths prove stable for a release cycle (a deliberate decision for a
future phase, not housekeeping).
