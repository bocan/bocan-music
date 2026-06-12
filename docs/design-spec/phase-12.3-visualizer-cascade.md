# Phase 12.3: Visualizer Mode "Cascade" (Scrolling Spectrogram Waterfall)

> Prerequisites: Phase 12.1 complete (Analysis v2, `PaletteResolver.rampStops`,
> `render(... time:)`).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A scrolling time-frequency heatmap: the newest spectrum column appears at the
right edge and the history slides continuously left, like a studio spectrogram.
Frequency runs bottom (20 Hz) to top (20 kHz); colour encodes magnitude. Unlike
every other mode, Cascade shows the *recent past* of the music, about six
seconds of it, so melodies and rhythms leave readable trails.

Canvas-based with a small persistent bitmap; visually nothing like Bars, Halo,
Starfield, or Nebula.

## Non-goals

- No full-resolution spectrogram (1024 bins); the 32 perceptual bands are the
  vertical resolution, deliberately chunky and stylised.
- No pause/scrub of the history.
- No axis labels or dB scale; this is art, not measurement.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/
├── Cascade.swift                    # NEW: renderer + history bitmap
├── VisualizerMode.swift             # + case cascade
└── VisualizerHost.swift             # + rebuildRenderer arm
```

## Visual design

- **History buffer.** A persistent 256 x 32 pixel BGRA `CGBitmapContext`
  (32 KB) used as a ring buffer of columns. Each new `Analysis` frame
  (about 43 per second, detected by comparing the frame against the previously
  consumed one) writes one column of 32 pixels at the cursor and advances it.
  256 columns at 43 Hz is roughly 6 seconds of history.
- **Drawing.** Each render, the bitmap is presented as two crops (cursor to
  end, start to cursor) laid side by side and scaled to the canvas with
  bilinear interpolation, low frequencies at the bottom. The 32-band
  chunkiness smooths into soft horizontal streams when scaled up.
- **Smooth scroll.** Data arrives at about 43 Hz but the canvas redraws at up
  to 60 Hz. Offset the blit horizontally by
  `columnWidth * (time - lastColumnTime) / columnPeriod` so scrolling is
  continuous, not stepped.
- **Now line.** A 1-pixel vertical line at the right edge, full palette
  brightness, marks "now"; the newest column glows slightly brighter for its
  first 150 ms (movement accent).
- **Onset ticks.** On `analysis.onset`, the new column's top two and bottom
  two pixels are written at full ramp intensity, leaving a subtle tick mark in
  the history; rhythms become visible as a dotted edge.

### Colour (the current method)

Pixels are coloured **at write time** through a 256-entry LUT built from
`PaletteResolver.rampStops(palette:analysis:time:)`, indexed by band magnitude.

- Static palettes build the LUT once per renderer lifetime.
- `thermal` is the natural fit (magnitude ramp by design).
- `drift` rebuilds the LUT when its base hue has moved by more than 1/256 of a
  cycle. Because history pixels keep the colour they were written with, a
  drifting palette paints a slow rainbow *across time*, old music in old
  colours. This is intended behaviour, not a bug; document it in code.
- `mono` and `accent` map magnitude to brightness of the single colour;
  `spectrum` and `ember` map magnitude through their hue ranges.

### Accessibility

- `reduceMotion`: no continuous scroll. The bitmap still accumulates, but the
  presented image updates once per second in discrete steps, and the
  sub-column offset and now-line glow are disabled.
- `reduceTransparency`: no change needed; the mode is fully opaque already.

## Definitions and contracts

```swift
case cascade               // VisualizerMode; displayName L10n "Cascade"
                           // symbolName "water.waves"
```

```swift
@MainActor
public final class Cascade: Visualizer {
    public init(
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool
    )
}
```

Internal state: `CGContext` (256 x 32, BGRA, sRGB), column cursor, colour LUT
(`[UInt32]` x 256), last consumed analysis identity, `lastColumnTime`,
cached `CGImage` (regenerated only when a column is written, not per render).

## Implementation plan

1. `VisualizerMode.cascade` + L10n key + pseudolocale; host arm. (Land complete
   within the PR.)
2. Bitmap ring buffer + LUT + column writes; static presentation (no scroll
   interpolation yet). Snapshot test from a scripted sequence of `Analysis`
   frames.
3. Two-crop scrolling presentation + sub-column smooth offset + now line +
   onset ticks.
4. Drift LUT regeneration; reduceMotion stepped mode.
5. Memory/perf validation (see test plan).

## Context7 lookups

- `use context7 CGBitmapContext draw pixels BGRA premultiplied`
- `use context7 SwiftUI GraphicsContext draw CGImage interpolation`
- `use context7 CGImage cropping performance ring buffer`

## Dependencies

None new.

## Test plan

- **Column write**: feeding one `Analysis` with band k = 1.0 and the rest 0
  writes exactly one column whose k-th pixel is the LUT's top entry.
- **Ring wrap**: after 300 frames the cursor has wrapped; the two-crop
  presentation places the newest column at the right edge (verify via a marker
  column's position in the rendered snapshot).
- **Frame dedup**: rendering 3 times between analysis updates writes one
  column, not three.
- **LUT correctness**: for each palette, LUT entry 0 is the darkest stop and
  entry 255 the brightest; thermal is monotonic in luminance.
- **Drift repaint**: advancing time by 90 s with drift selected yields a
  different LUT; history pixels written earlier are untouched.
- **reduceMotion**: presented image identical across renders within the same
  1 s window.
- **Snapshots**: a scripted 64-frame sequence (sweep + two onsets) across all
  six palettes at one size.
- **Memory**: bitmap and LUT allocations happen in `init` only; long-run
  render of 10k frames shows no growth (ties into the phase 12 long-run gate).

## Acceptance criteria

- [ ] `cascade` selectable, localized, pseudolocale green.
- [ ] History scrolls smoothly at 60 fps while data arrives at 43 Hz.
- [ ] All colour through `PaletteResolver.rampStops`; six palettes render.
- [ ] Onset ticks visible with percussive material from the real tap.
- [ ] reduceMotion stepped mode works.
- [ ] Snapshot + unit tests as listed; `make lint && make test-ui` green.
- [ ] Steady-state render allocates nothing beyond the cached `CGImage` swap.

## Gotchas

- **CGContext y-axis.** CoreGraphics origin is bottom-left; SwiftUI's is
  top-left. Decide once where band 0 (bass) lives and assert it in a snapshot,
  or the spectrogram renders upside down and nobody notices for a week.
- **`makeImage()` copies.** Calling it per render at 60 fps copies 32 KB each
  time (about 2 MB/s, fine), but regenerating only on column writes (43 Hz)
  is free to do and keeps the render path allocation-clean. Cache the image.
- **Premultiplied alpha.** Write opaque pixels (alpha 255) into the BGRA
  buffer; premultiplication bugs show up as dark fringes at colour boundaries.
- **Interpolation control.** `GraphicsContext` does not expose interpolation
  quality directly; use `context.withCGContext` and set
  `interpolationQuality = .low` (bilinear) explicitly so the look is stable
  across OS versions.
- **Analysis identity.** `Analysis` is a value type with no counter; detect
  "new frame" via a sequence number added in `VisualizerViewModel`, not by
  comparing 32 floats. (Add `frameIndex: UInt64` to `Analysis` in this phase;
  it is backward compatible and Starfield reuses it.)
- **Don't tie history length to canvas width.** 256 columns regardless of
  window size; resizing rescales the same history rather than reallocating.

## Handoff

Phase 12.4 (Starfield) reuses `Analysis.frameIndex` for per-frame triggers.
Nebula (12.5) reuses the `rampStops` LUT idea as a Metal texture.
