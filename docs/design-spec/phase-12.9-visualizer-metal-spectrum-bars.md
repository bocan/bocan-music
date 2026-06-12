# Phase 12.9: Metal Spectrum Bars (Instanced Quads)

> Prerequisites: Phases 12.6 and 12.7 complete. 12.8 is recommended first but
> not required.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Convert Spectrum Bars to Metal using instanced rendering: 32 bar instances
plus 32 peak-marker instances, one draw call each. This phase proves the
instancing pattern that Halo's ripples (12.10) and Starfield's 500 stars
(12.11) depend on.

Be honest about value: Spectrum Bars is the cheapest Canvas mode and the
auto-simplify fallback target; this conversion is about pattern-proving and
consistency, not a visible win. If schedule pressure forces a cut, cut this
phase, not 12.10/12.11.

## Non-goals

- No visual changes (bar geometry, rounded caps, peak gravity all contract).
- No removal of `SpectrumBars.swift`.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/Metal/
└── MetalSpectrumBars.swift          # NEW

Modules/UI/Sources/UI/Resources/Shaders/
└── SpectrumBars.metal               # NEW

MetalVisualizerFactory                # + .spectrumBars arm
```

## Behavioural contract (verbatim from SpectrumBars.swift, do not re-derive)

- Layout: `barSpacing = 2 pt`;
  `barWidth = (width - spacing * (bandCount + 1)) / bandCount`;
  bar i at `x = spacing + i * (barWidth + spacing)`;
  `maxBarHeight = height - 4 pt`; bar grows from the bottom edge.
- Shape: rounded rectangle, corner radius `min(3, barWidth / 2)` (all four
  corners, matching `RoundedRectangle.path(in:)`).
- Colour: `PaletteResolver.color(palette:position: i / (bandCount - 1),
  magnitude: bands[i], analysis:time:)`, 32 CPU resolutions per frame.
- Bar opacity: 1.0 normally; 0.5 under reduceMotion; forced 1.0 under
  reduceTransparency (reduceTransparency wins).
- Peak markers (skipped entirely under reduceMotion): 2 pt tall, full bar
  width, at `y = height - peakHold[i] * maxBarHeight - 3`, bar colour at 0.9
  opacity.
- Peak physics, **frame-based, not dt-based** (preserve the quirk for parity;
  note it in code): on `magnitude >= peakHold[i]` set hold to magnitude,
  velocity 0, counter 30; else while counter > 0 decrement; else
  `velocity += 0.004; peakHold = max(0, peakHold - velocity)`. One physics
  step per rendered frame, exactly like the Canvas version (meaning peaks
  fall faster at 120 fps than at 30; that is existing behaviour, keep it).

## Metal design

- CPU `update`: run the peak physics, resolve 32 colours via
  `ColorPacking.simd`, build 64 instance records into a `FrameRing` slot
  (32 bars, then 32 peaks; peak count 0 under reduceMotion):

  ```swift
  struct BarInstance {                  // 48 bytes, assert stride
      var rectMin: SIMD2<Float>         // pixel space, top-left
      var rectMax: SIMD2<Float>         // pixel space, bottom-right
      var color: SIMD4<Float>           // sRGB, alpha pre-applied
      var cornerRadius: Float           // pixels; 0 for peak markers
      var pad: SIMD2<Float>
      var pad2: Float
  }
  ```

- Vertex shader: 6 vertices per instance (two triangles) generated from
  `vertex_id % 6` corner lookup of rectMin/rectMax, converted to NDC;
  passes the rect, radius, and colour to the fragment stage.
- Fragment shader: rounded-rectangle SDF (`length(max(abs(p - center) -
  (halfSize - r), 0)) - r`); discard or alpha-zero outside; the SDF edge
  gives one pixel of analytic anti-aliasing via `smoothstep` on the
  distance, which closely matches Core Graphics' antialiased path fills.
- One pipeline, alpha blending enabled, single
  `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
  instanceCount: n)` call.
- Peak markers are the same instance type with `cornerRadius = 0` (plain
  rect), drawn in the same instanced call (they are later instances, so they
  draw over bars, matching Canvas order).

## Implementation plan

1. Bars only: instance buffer, SDF shader, layout parity snapshot. Commit.
2. Peak physics port (copy the algorithm; unit-test against golden values
   produced by the Canvas implementation) + peak instances. Commit.
3. a11y variants + full snapshot suite + factory arm. Commit.

## Context7 lookups

- `use context7 Metal instanced rendering instance_id drawPrimitives`
- `use context7 rounded rectangle SDF signed distance fragment shader`
- `use context7 Metal analytic antialiasing smoothstep fwidth`

## Test plan

CPU-side:

- **Layout parity**: for width 400 / 32 bands, bar x positions and widths
  match the Canvas formulas to Float epsilon (golden array).
- **Peak physics parity**: feed a scripted magnitude sequence (rise, hold,
  fall) through both the Canvas `updatePeak` (via a test seam or a copied
  reference implementation in the test) and the Metal port; assert identical
  `peakHold` trajectories over 120 frames.
- **Instance buffer**: reduceMotion yields 32 instances (no peaks) with
  alpha 0.5; reduceTransparency yields alpha 1.0 even when reduceMotion is
  also set; normal yields 64.
- **Stride assertion**: `MemoryLayout<BarInstance>.stride == 48`.

GPU (local-only):

- **Snapshots**: fixed mid-spectrum analysis across all six palettes at
  400 x 400; reduceMotion and reduceTransparency variants; one tall-bar case
  (band = 1.0) confirming the cap radius and the 4 pt headroom.

## Acceptance criteria

- [ ] Spectrum Bars renders via Metal; `visualizer.forceCanvas` flips back.
- [ ] Peak trajectories byte-match the Canvas physics in tests.
- [ ] Auto-simplify still targets `.spectrumBars` and the existing
      `autoSimplify` no-op guard for the current mode is untouched.
- [ ] Canvas `SpectrumBars` untouched; existing suites pass unchanged.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- **Do not convert the peak physics to dt-based.** It is frame-based in the
  Canvas version; changing it breaks parity and the golden tests. If someone
  wants dt-based physics, that is a separate behaviour change for both
  renderers, out of scope.
- **The SDF anti-aliased edge vs Core Graphics.** Perceptual precision 0.98
  absorbs the difference at 2x scale; if a snapshot diff concentrates
  entirely on bar edges, tune the smoothstep width (one pixel via
  `fwidth`), not the geometry.
- **Alpha is pre-applied on the CPU** (`color.a` carries the 0.5/0.9/1.0
  opacity); the fragment shader multiplies by SDF coverage only. Applying
  opacity in both places renders bars twice as transparent.
- **Instance order is draw order**: bars first, peaks second, or peaks
  vanish under bars at high magnitudes.

## Handoff

12.10 (Halo) reuses the instanced-SDF pattern for ripples and the centre
glow; 12.11 (Starfield) scales it to 500 instances.
