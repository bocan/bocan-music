# Phase 12 — Visualizers

> Prerequisites: Phases 0–11 complete. `AudioEngine` exposes a tap point (Phase 1).
>
> Read `phases/_standards.md` first.

## Goal

Audio-reactive visuals. At least three distinct modes: spectrum bars, oscilloscope, and one more ambitious Metal-based mode. Fullscreen option. Performance-safe on laptops.

## Non-goals

- Shader-plugin ecosystem — no Milkdrop ports for v1.
- Per-track saved visualizer settings — global is enough.
- Video output / external display — stretch only.

## Outcome shape

```
Modules/AudioEngine/Sources/AudioEngine/Tap/
├── AudioTap.swift                   # installTap adapter, AsyncStream<AudioSamples>
└── FFTAnalyzer.swift                # vDSP-backed FFT and windowing

Modules/UI/Sources/UI/Visualizers/
├── VisualizerHost.swift             # Container view, drives chosen mode
├── VisualizerMode.swift             # Enum + registry
├── Visualizer.swift                 # Protocol: render(sample:)
├── SpectrumBars.swift               # Canvas-based
├── Oscilloscope.swift               # Canvas-based
├── FluidMetal.swift                 # Metal-based (particles + low-pass)
├── FullscreenWindow.swift           # Separate Scene for fullscreen
├── VisualizerSettingsView.swift
└── ViewModels/VisualizerViewModel.swift
```

## Implementation plan

1. **`AudioTap`** — installs a tap on the output mixer node at buffer size 1024 (configurable). Uses `AVAudioEngine.installTap(onBus:bufferSize:format:block:)`. Converts the incoming `AVAudioPCMBuffer` into a lightweight `AudioSamples` struct:
   ```swift
   public struct AudioSamples: Sendable {
       public let timeStamp: AVAudioTime
       public let sampleRate: Double
       public let mono: [Float]                 // downmixed L+R for analysis
       public let left: [Float]
       public let right: [Float]
       public let rms: Float
       public let peak: Float
   }
   ```
   Publishes via `AsyncStream<AudioSamples>` with a small bounded buffer; drop-oldest policy on backpressure. Taps have **zero allocation** in the render block: preallocate storage, copy in, hand a `Sendable` snapshot out on the actor.

2. **`FFTAnalyzer`** (Accelerate `vDSP`):
   - Size 2048 with 50% overlap.
   - Hann window precomputed.
   - Returns `magnitudes: [Float]` (1024 bins), linear or log-scaled.
   - Smooth across frames with an exponential moving average (attack fast, release slow — looks better).
   - Convert bin magnitudes to perceptual bands (e.g. 32 or 64 log-spaced bands) for the bar visualizer.

3. **`Visualizer` protocol**:
   ```swift
   @MainActor
   public protocol Visualizer: AnyObject {
       func render(into context: GraphicsContext, size: CGSize, samples: AudioSamples, analysis: Analysis)
   }
   public struct Analysis: Sendable {
       public let bands: [Float]          // perceptual bands 0...1
       public let rms: Float
       public let peak: Float
   }
   ```

4. **Implementations**:
   - **Spectrum Bars**: 32 log-spaced bars, rounded caps, gradient by band index, peak-hold markers that fall with gravity. Canvas + TimelineView @ 60Hz.
   - **Oscilloscope**: direct waveform stroke using a downsampled recent window; optional XY mode (L vs R stereo Lissajous) as a variant. Canvas.
   - **Fluid (Metal)**: particle system, 2–4k points, accelerated by bass energy (low bands), colour drifts with spectral centroid. Metal view via `MetalView` + a compute shader feeding a vertex buffer. Target 60fps on integrated GPUs.

5. **`VisualizerHost`**:
   - Swaps modes without tearing down the tap.
   - TimelineView drives redraws at 60Hz; the Metal path uses its own `CADisplayLink` equivalent (`CVDisplayLink` on macOS).
   - Respects `reduceMotion` by: bars → calm still-life style with minimal motion, oscilloscope → paused with last frame, fluid → disabled (falls back to bars).

6. **Fullscreen mode**:
   - Separate `Window` opened via `⌘⇧F`. Covers the screen. `Esc` closes.
   - Black background; hide cursor after 2s of no movement.
   - If multiple displays, picker to choose display.

7. **Performance budget**:
   - 60fps on an M1.
   - `CVDisplayLink` / `TimelineView` with `DispatchTimeoutResult`-style logging of late frames.
   - MetricKit `signpost` around render; any frame > 20ms logs at `.debug`.
   - Hard cap: if sustained frame rate drops below 30fps for 3 seconds, auto-switch to a simpler mode and show a toast.
   - On battery, cap to 30fps by default (user setting).

8. **Settings**:
   - Mode picker.
   - FPS cap (30 / 60 / unlimited).
   - Sensitivity slider (maps input levels to output).
   - Palette picker (4 curated).
   - "Use simpler visualizer on battery" toggle.

9. **Integration**:
   - Toggle button in the transport strip opens the visualizer pane (right side overlay in main window, separate window in fullscreen).
   - Pane can sit side-by-side with lyrics or replace it; the two are mutually exclusive in the same overlay area.

## Context7 lookups

- `use context7 AVAudioEngine installTap zero allocation`
- `use context7 Accelerate vDSP FFT real Hann window`
- `use context7 SwiftUI Canvas TimelineView performance 60fps`
- `use context7 Metal compute shader particles SwiftUI`
- `use context7 CVDisplayLink macOS Swift`

## Dependencies

None new. Uses `Accelerate`, `Metal`, `MetalKit`.

## Test plan

- **FFT correctness**: feed a pure 1 kHz sine at a known sample rate; the bin containing 1 kHz is dominant within 3 dB of the analytical value.
- **Windowing**: Hann window is symmetric, peak 1.0 at centre.
- **Band mapping**: log-spaced bands are monotonic in frequency; no NaN.
- **Smoothing**: bands decay after silence with expected time constants.
- **Tap**:
  - Does not drop samples under normal playback (cross-check tapped buffers against source buffer count via counters).
  - Does not affect playback timing (a parallel test plays a reference file with and without the tap and compares output via a loopback).
- **Long-run**: render for 10 minutes in headless mode; no memory growth; no leaked Tasks.
- **Perf**: synthetic 60Hz target; test records actual frame times using a fake clock; assert 95th percentile under the target.
- **Fullscreen**: window opens and closes cleanly; does not retain audio tap after close.
- **Accessibility**: visualizer layer has an `accessibilityLabel` describing the current mode; `reduceMotion` path verified.

## Acceptance criteria

- [x] At least three visualizer modes.
- [x] Fullscreen works.
- [x] 60fps on M-series; 30fps on battery by default.
- [x] No audible impact when a visualizer is running.
- [ ] No memory growth over a long session (< 10 MB drift in 30 min).
- [x] Snapshot tests for the non-Metal modes cover a known analysis input.
- [x] 80%+ coverage on the analysis path (Metal render paths are exempt from the line-coverage goal; document).
- [x] `make lint && make test-coverage` green.

## Gotchas

- **Render block rules**: the tap block runs on a real-time thread. No allocations. No `print`. No `os.Logger` calls — buffer events and log on the consumer thread.
- **`AVAudioEngine.installTap`** doubles up memory if called twice; guard against re-installing.
- **Format of tap**: request a consistent format (`Float32, non-interleaved, 2ch, sampleRate: engine.mainMixerNode.outputFormat`). Don't rely on the output device's rate at call time — capture it once.
- **`TimelineView`** in SwiftUI can be laggy for complex canvases; test the bars view with `.drawingGroup()` and measure both.
- **`CVDisplayLink`** vs `DisplayLink` on macOS: `CVDisplayLink` is the right API on macOS 14+; `DisplayLink` (ported from iOS) exists in newer SDKs but verify availability. Pick one and stick.
- **Metal on battery**: integrated GPUs with frequency scaling can spike latency. Always cap the frame rate on battery to keep UX predictable.
- **Colour perception**: spectrum bars with a rainbow gradient is the default but many users hate rainbows — include a monochrome accent palette.
- **`reduceTransparency`**: the fluid mode's blending looks bad when flattened; have a deliberate fallback rather than letting the system do it.
- **Fullscreen on external display**: capture the correct screen; `NSScreen.screens` order isn't stable.
- **Metal warm-up**: first frame after opening can hitch — show a simple placeholder until the first real frame renders.
- **Audio discontinuity**: when a new track starts, the tap sees a format change if gapless is mixed-format. Re-capture format in the tap consumer on change.

## Handoff

Phase 13 (Scrobbling) expects:

- The tap doesn't interfere with the Now-Playing tracker; scrobble timing reads from `engine.currentTime`, not tap data.
- Visualizer can be disabled from a setting; its lifecycle is independent of playback state.
