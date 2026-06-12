# Phase 12.7: Metal Oscilloscope (First Mode Conversion)

> Prerequisites: Phase 12.6 complete (MetalVisualizer protocol, factory,
> MetalVisualizerView, PolylineRibbon, FrameRing, ColorPacking,
> MetalOffscreenRenderer).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Convert the Oscilloscope to Metal as the proving run for the 12.6
infrastructure: one polyline, one uniform colour, the simplest possible
geometry. The Canvas `Oscilloscope` stays in the codebase as the fallback and
the parity reference. **The rendered output must be visually indistinguishable
from the Canvas version**; the deliverable is latency and CPU headroom, not a
redesign.

## Non-goals

- No visual changes of any kind, including "improvements".
- No removal of `Oscilloscope.swift`.
- No anti-aliasing work beyond what the default sample count gives; the
  1.5 pt ribbon at Retina density does not need MSAA.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/Metal/
└── MetalOscilloscope.swift          # NEW

Modules/UI/Sources/UI/Resources/Shaders/
└── Oscilloscope.metal               # NEW

MetalVisualizerFactory                # + .oscilloscope arm; supports() true
```

## Behavioural contract (verbatim from Oscilloscope.swift, do not re-derive)

- **Waveform variant** (the only variant wired into the host today; preserve
  the `variant` init parameter and implement both):
  - Downsample `samples.mono` to at most 512 points:
    `step = max(1, count / min(512, count))`, indices
    `stride(from: 0, to: count, by: step)`.
  - Point mapping: `x = width * i / count`,
    `y = midY - mono[i] * midY * 0.9` where `midY = height / 2`.
  - Trace: stroke width 1.5 pt.
  - Centre line: horizontal at `midY`, width 0.5 pt, trace colour at 15%
    opacity.
  - Fewer than 2 mono samples: draw nothing (only the clear).
- **Lissajous variant**: `count = min(left.count, right.count)`, same
  downsampling; `x = cx + left[i] * scale`, `y = cy - right[i] * scale`,
  `scale = min(cx, cy) * 0.9`; stroke 1.5 pt; no centre line.
- **Colour**: `PaletteResolver.color(palette:position: 0, magnitude: 1,
  analysis:time:)`, resolved once per frame on the CPU (mono stays white,
  accent stays full opacity).
- **reduceMotion**: freeze on the first captured `AudioSamples` and keep
  rendering that buffer (the Canvas version stores `lastSamples` once and
  never updates it).
- **reduceTransparency**: no effect (matches Canvas: the oscilloscope ignores
  it).

## Metal design

All geometry on the CPU in `update`, all of it trivial:

1. **Coordinate spaces, decided once for the whole phase series.** `update`
   receives `drawableSize` in pixels. Do all geometry math in pixel space
   (Canvas orientation: y grows downward), then convert finished vertices to
   NDC (x,y in -1...1, NDC y grows upward, so negate y once) just before
   writing the vertex buffer.

   Stroke widths: the Canvas reference uses points; pixels = points *
   `pixelsPerPoint`, where
   `let pixelsPerPoint: CGFloat = NSScreen.main?.backingScaleFactor ?? 2`
   is captured once at init. Add an internal `pixelsPerPointOverride` test
   seam (snapshot tests set it to 1 so references are scale-independent).
   Document both in code; every later conversion phase reuses this recipe
   verbatim.

   Downsample `samples.mono` per the behavioural contract and map points
   into pixel space.

2. Build the trace strip via
   `PolylineRibbon.strip(points:width: 1.5 * pixelsPerPoint, closed: false)`,
   then the centre-line strip (2 points, width 0.5 * pixelsPerPoint). Convert
   strips to NDC and write both into one `FrameRing` slot (trace strip
   followed by centre strip; remember both vertex counts).

3. Uniforms (one struct, 32 bytes):

   ```swift
   struct OscilloscopeUniforms {     // MSL mirror: same field order
       var traceColor: SIMD4<Float>  // sRGB-encoded, from ColorPacking.simd
       var lineColor: SIMD4<Float>   // traceColor with alpha 0.15
   }
   ```

4. Shader (`Oscilloscope.metal`): vertex pulling of `float2` NDC positions,
   pass-through vertex function; fragment returns the colour selected by a
   `colorIndex` passed via `setVertexBytes`/separate draw calls. Two draw
   calls: centre line first (under), trace second (over), matching Canvas
   draw order... Canvas draws trace first, centre line second (over the
   trace at 15% alpha). **Match Canvas order: trace first, then centre line.**
   Enable standard alpha blending on the pipeline
   (`sourceAlpha`/`oneMinusSourceAlpha`) for the 15% line.

5. `encode`: set pipeline, bind the FrameRing buffer, draw both triangle
   strips. Buffer lifecycle: `ring.acquire()` in `update` (once per frame),
   `ring.release(when:)` in `didEncode(commandBuffer:)` (the 12.6 protocol
   hook that exists exactly for this pairing). Acquire and release must each
   happen exactly once per frame or the semaphore drifts and the view
   deadlocks after three frames.

## reduceMotion / reduceTransparency

- `reduceMotion`: in `update`, capture the first non-empty `AudioSamples` into
  `frozenSamples` and use it for every subsequent frame. The strip is rebuilt
  each frame from the same data (cheap, keeps the code path single) or cached;
  either is acceptable, caching preferred.
- `reduceTransparency`: ignored, matching Canvas.

## Implementation plan

1. `Oscilloscope.metal` + `MetalOscilloscope` rendering the waveform variant;
   factory arm + `supports`. Verify live behind `visualizer.forceCanvas`
   toggling. Commit.
2. Lissajous variant + reduceMotion freeze + centre line blending. Commit.
3. Snapshot suite via `MetalOffscreenRenderer` (see test plan) + parity
   eyeball against Canvas snapshots; document the comparison in the PR.
   Commit.

## Context7 lookups

- `use context7 Metal vertex pulling vertex_id buffer triangle strip`
- `use context7 MTLRenderPipelineDescriptor alpha blending sourceAlpha`
- `use context7 Metal setVertexBytes small uniform data`

## Test plan

- **Downsampling parity**: a deterministic 2048-sample sine produces the same
  point set (same indices, same x/y values within Float epsilon) as the
  Canvas implementation's loop; assert against a small golden array.
- **NDC mapping**: sample value +1.0 maps to y = +0.9 of half-height in NDC
  (top half); -1.0 to -0.9; x spans -1...1 inclusive of the first point.
- **Empty input**: mono count < 2 builds zero vertices; encode emits no draw
  (assert via vertex-count state, not GPU introspection).
- **reduceMotion**: feeding three different sample buffers builds identical
  vertex data after the first (compare cached strip).
- **Uniform layout**: `MemoryLayout<OscilloscopeUniforms>.stride == 32`.
- **Snapshots** (GPU, local-only, CI-disabled): waveform sine at fixed
  analysis across all six palettes at 400 x 400; lissajous circle (left=sin,
  right=cos) on one palette; reduceMotion variant. Record, then eyeball
  against the Canvas oscilloscope's output for parity.

## Acceptance criteria

- [ ] Oscilloscope renders via Metal when a device exists;
      `visualizer.forceCanvas` flips it back live.
- [ ] Visual parity with Canvas confirmed by side-by-side snapshots in the PR.
- [ ] Auto-simplify watchdog still receives ticks (manual check: log or
      breakpoint in `recordFrameTick` while Metal oscilloscope runs).
- [ ] Canvas `Oscilloscope` untouched; its tests pass unchanged.
- [ ] No new user-facing strings.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- **This phase is the template.** Patterns established here (pixelsPerPoint
  seam, didEncode/FrameRing pairing, snapshot-suite shape) are copied by
  12.8 to 12.12; sloppiness here multiplies by five.
- **Draw order matters for blending**: trace, then 15% centre line, matching
  Canvas. Reversed order changes the overlap pixels and fails parity.
- **Do not draw `.lineStrip` primitives.** They are 1-pixel hairlines and
  look broken at Retina density. Ribbon or nothing.
- **The y-axis flips twice.** Canvas y grows downward; NDC y grows upward.
  The contract formulas above are in Canvas orientation; negate once at the
  NDC conversion and assert orientation in a unit test (sample +1.0 must be
  in the TOP half), or the waveform renders inverted and a sine looks
  identical, hiding the bug until someone plays a kick drum.
- **`samples.mono` can be empty** (tap not yet delivering); guard before
  dividing by count.

## Handoff

12.8 (Cascade) and every later conversion reuse the patterns established
here: the pixel-space-then-NDC recipe, the `pixelsPerPoint` seam, the
acquire/didEncode FrameRing pairing, and the offscreen snapshot-suite shape.
