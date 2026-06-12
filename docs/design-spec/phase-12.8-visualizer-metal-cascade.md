# Phase 12.8: Metal Cascade (Spectrogram on a GPU Texture)

> Prerequisites: Phases 12.6 (foundations, including the `PaletteRampLUT`
> extraction) and 12.7 (Oscilloscope conversion; establishes the
> pixelsPerPoint seam, FrameRing pairing, and snapshot patterns) complete.
>
> Read `docs/design-spec/_standards.md` first, then
> `phase-12.3-visualizer-cascade.md` for the original design rationale.

## Goal

Convert Cascade to Metal. This is the conversion with the clearest win: the
history ring buffer becomes an `MTLTexture` the GPU samples directly, the
two-crop `CGImage` presentation becomes a texture-coordinate wrap in the
fragment shader, and the per-frame `makeImage()` copy disappears entirely.
The Canvas `Cascade` stays as fallback and parity reference.

## Non-goals

- No visual changes. The chunky 32-band look, the colours, the onset ticks,
  the now line, and the "history keeps the colour it was written with" drift
  behaviour are all contract.
- No resolution increase (the 256 x 32 history is the design, not a limit).
- No removal of `Cascade.swift`.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/Metal/
└── MetalCascade.swift               # NEW

Modules/UI/Sources/UI/Resources/Shaders/
└── Cascade.metal                    # NEW

MetalVisualizerFactory                # + .cascade arm
```

## Behavioural contract (verbatim from Cascade.swift, do not re-derive)

- History: 256 columns x 32 bands, BGRA, ring buffer with write cursor;
  new analysis frames detected via `analysis.frameIndex != lastFrameIndex`.
- Column write: per band, `lutIndex = min(255, Int(magnitude * 255))`;
  memory row = `bandCount - 1 - band` (row 0 = treble at top, row 31 = bass
  at bottom). Onset frames overwrite rows 0, 1, 30, 31 with `lut[255]`.
- LUT: `PaletteRampLUT` (shared since 12.6), colours applied at write time;
  drift palette rebuilds the CPU LUT when base hue moves more than 1/256
  cycle, history pixels keep their original colours.
- Presentation: newest column at the right edge; screen-left shows the oldest.
  Sub-column smooth scroll offset =
  `columnWidth * clamp((time - lastColumnTime) / columnPeriod, 0, 1)` where
  `columnPeriod = 1/43 s`.
- Now line: 1 pt vertical at the right edge, colour
  `PaletteResolver.color(position: 1, magnitude: 1)`. Glow: white overlay on
  the now line fading linearly over the 150 ms after a column write, peak
  alpha 0.5.
- reduceMotion: no scroll offset, no now line, no glow; the presented image
  updates in discrete steps at most once per second while columns continue
  to accumulate.
- reduceTransparency: no change (mode is fully opaque).

## Metal design

### Resources (created in init)

- `historyTexture`: 256 x 32, `.bgra8Unorm`, `storageModeShared`,
  usage `[.shaderRead]`. Cleared to opaque black at init by writing a zeroed
  staging array via `replace(region:)`.
- `displayTexture` (reduceMotion only): same descriptor plus `.shaderWrite`
  is unnecessary; it is a blit destination, so no extra usage flags. See the
  stepped-mode section.
- `lut: PaletteRampLUT` kept CPU-side only. The shader never sees the LUT;
  colours are baked into the texture at write time, which is what preserves
  the drift-history behaviour for free.
- Staging column: a reusable `[UInt32]` of count 32.
- Pipeline: fullscreen quad (vertex pulling of 4 hardcoded NDC corners or a
  vertex_id-computed fullscreen triangle; the triangle is simpler), sampler
  with `minFilter/magFilter = .linear`, `sAddressMode = .repeat`,
  `tAddressMode = .clampToEdge`.

### Per-frame `update`

1. `lut.rebuildIfNeeded(analysis:time:)` (drift only ever returns true).
2. If `analysis.frameIndex != lastFrameIndex`: fill the staging column
   exactly like `Cascade.writeColumn` (same row flip, same onset rows), then

   ```swift
   historyTexture.replace(
       region: MTLRegionMake2D(cursor, 0, 1, 32),
       mipmapLevel: 0,
       withBytes: stagingColumn,
       bytesPerRow: 4              // one pixel per row of the 1-wide region
   )
   ```

   advance the cursor mod 256, record `lastColumnTime`.
3. Pack uniforms (one struct, assert stride in tests):

   ```swift
   struct CascadeUniforms {              // 48 bytes
       var nowColor: SIMD4<Float>        // sRGB-encoded
       var cursorPlusOffset: Float       // cursor + subColumnFraction, columns
       var nowLineWidthUV: Float         // (1 pt * pixelsPerPoint) / drawableWidth
       var glowAlpha: Float              // 0 when expired or reduceMotion
       var showNowLine: Float            // 1.0 / 0.0 (reduceMotion off/on)
       var pad: SIMD4<Float>             // explicit padding to 48
   }
   ```

   `subColumnFraction = clamp((time - lastColumnTime) / columnPeriod, 0, 1)`,
   zero under reduceMotion.

### Fragment shader (`Cascade.metal`)

For screen UV `u` in 0...1 left to right, `v` in 0...1 top to bottom:

```
texU = (u * 256.0 + cursorPlusOffset) / 256.0;   // sampler wraps via .repeat
texV = v;                                        // row 0 treble at top
color = history.sample(s, float2(texU, texV));
if (showNowLine > 0.5 && u > 1.0 - nowLineWidthUV) {
    color = mix(color, nowColor, nowColor.a);
    color = mix(color, float4(1,1,1,1), glowAlpha);
}
return color;
```

Derivation note for the spec reader: screen x = 0 must show the column at
`cursor` (the oldest), x = right edge shows `cursor - 1` (the newest), and
the sub-column offset slides everything left between column writes. The
formula above does exactly that; validate it with the marker-column test
before trusting it.

### reduceMotion stepped mode

The Canvas version snapshots `cachedImage` once per second. The Metal
equivalent: keep `displayTexture`; at most once per second (same gating logic
as `Cascade.processFrame`, including the nil "never stepped" sentinel), blit
`historyTexture` to `displayTexture` with a `MTLBlitCommandEncoder` at the
top of the host's command buffer (do the blit inside `encode` by requesting
a blit encoder? No: `encode` receives a render encoder only).

**Decided recipe**: the renderer keeps a `needsStepBlit` flag set in
`update`. `didEncode(commandBuffer:)` does nothing here; instead the blit is
performed in `update` with its own tiny command buffer from a private queue
created at init (`device.makeCommandQueue()`), committed without waiting.
32 KB blit, microseconds, once per second. The fragment shader samples
`displayTexture` when reduceMotion, `historyTexture` otherwise, with
`cursorPlusOffset` frozen at the value captured at the last step (store
`steppedCursor`). This keeps the presented image bit-stable between steps,
which is the contract the Canvas tests assert.

## Implementation plan

1. `MetalCascade` + shader: history texture, column writes, static
   presentation with cursor wrap (no sub-column offset yet). Marker-column
   unit test + first snapshot. Commit.
2. Sub-column smooth offset + now line + glow. Commit.
3. reduceMotion displayTexture stepped path. Commit.
4. Full snapshot suite (all six palettes + both a11y variants, mirroring
   `CascadeSnapshotTests` and its 64-frame scripted sweep) + parity eyeball
   in the PR. Commit.

## Context7 lookups

- `use context7 MTLTexture replace region bytesPerRow single column`
- `use context7 Metal sampler address mode repeat clamp texture wrap`
- `use context7 Metal fullscreen triangle vertex_id no vertex buffer`
- `use context7 MTLBlitCommandEncoder copy texture to texture`

## Test plan

CPU-side (no GPU):

- **Column staging parity**: for a fixed analysis, the staging column bytes
  equal the column the Canvas `Cascade.writeColumn` produces (read back via
  `pixelAt`), including the onset-tick rows and the row flip.
- **Cursor/dedup/ring-wrap**: port the existing `CascadeTests` cases
  (same frameIndex three times writes once; 300 frames wraps to cursor 44).
- **Uniforms**: `MemoryLayout<CascadeUniforms>.stride == 48`;
  `subColumnFraction` is 0 at write time, approaches 1 at `columnPeriod`,
  clamps beyond; reduceMotion forces 0 and `showNowLine = 0`.
- **Stepped gating**: two updates 0.3 s apart blit once; 1.1 s apart blits
  twice; `steppedCursor` only changes on blit frames.

GPU (local-only, CI-disabled):

- **Marker column orientation**: write one column with band 15 = 1.0, render
  offscreen, assert the bright pixel cluster is in the right half and the
  *bottom* half when the marker band is bass-side (band 15 of 32 sits mid
  height; also test band 0 lands at the bottom and band 31 at the top). This
  is the upside-down-spectrogram guard from 12.3, re-asserted for the new
  pipeline.
- **Snapshots**: scripted 64-frame sweep + two onsets across all six
  palettes at 600 x 300; reduceMotion and reduceTransparency variants.

## Acceptance criteria

- [ ] Cascade renders via Metal; `visualizer.forceCanvas` flips back live.
- [ ] Marker-column orientation test passes (bass bottom, treble top, newest
      right).
- [ ] Drift palette: history keeps old colours while new columns use the
      rebuilt LUT (visible in a scripted snapshot, same as Canvas).
- [ ] reduceMotion stepped mode bit-stable between steps.
- [ ] Canvas `Cascade` untouched; all existing suites pass unchanged.
- [ ] `make lint && make test-ui && make test-coverage` green.

## Gotchas

- **`bytesPerRow` for a 1-wide region is 4**, not 256 * 4. Getting this
  wrong corrupts adjacent columns in a diagonal smear that only shows after
  a few seconds of playback.
- **The repeat-sampler seam.** With `.repeat` addressing and linear
  filtering, the outermost half-texel at each screen edge blends the newest
  and oldest columns together. This is at most one screen-edge pixel column
  and invisible in practice; do not "fix" it with an inset that shifts the
  whole image off its Canvas-parity alignment. Note it in code.
- **Texture row 0 is the top.** Same convention as the CGImage path, but the
  fullscreen-triangle UV derivation can silently flip v depending on how the
  triangle is constructed. The orientation test exists because this WILL be
  wrong on the first try roughly half the time.
- **Never sample `historyTexture` while replacing the same column region in
  the same frame.** Order in `update` is: replace first, then encode samples
  it. `replace(region:)` on a shared-storage texture is immediate and safe
  before the command buffer is committed; do not move column writes into a
  completion handler.
- **The private blit queue** (stepped mode) must be created once at init.
  Creating a command queue per blit leaks Metal objects at one per second.
- **Glow timing uses render time, not column time**: `age = time -
  lastWriteTime` evaluated per frame, exactly like Canvas; precomputing the
  alpha at write time freezes the glow.

## Handoff

12.9 (Spectrum Bars) needs nothing new from this phase. 12.12 (Nebula) reuses
the `PaletteRampLUT.makeTexture`/`upload` path this phase exercises first;
any API friction found here should be fixed here, not worked around.
