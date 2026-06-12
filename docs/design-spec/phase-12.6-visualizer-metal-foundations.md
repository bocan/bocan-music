# Phase 12.6: Metal Visualizer Foundations (MetalVisualizer Protocol + Shared Infrastructure)

> Prerequisites: Phases 12.1 (Analysis v2, `PaletteResolver`), 12.2 (Halo),
> 12.3 (Cascade, `Analysis.frameIndex`) complete and on `main`.
>
> Read `docs/design-spec/_standards.md` first.
>
> **Motivation.** The Canvas visualizers render through SwiftUI Canvas plus
> Core Graphics plus `.drawingGroup()`, several layers above the GPU. They hold
> 60 fps but with visible latency and CPU cost. This phase builds the shared
> Metal rendering infrastructure; phases 12.7 to 12.12 move individual modes
> onto it. **This phase has zero user-visible changes.** No new modes, no
> changed pixels, no new strings.

## Goal

A `MetalVisualizer` protocol parallel to the existing `Visualizer` protocol,
plus everything a converted mode needs so the per-mode phases stay small:

1. `MetalVisualizer` protocol: CPU-state update and GPU encoding split into two
   methods so the CPU side stays fully unit-testable without a GPU.
2. `MetalVisualizerView`: the `NSViewRepresentable` `MTKView` host with frame
   pacing, the FPS watchdog tick, warm-up fade, render-scale support, and
   correct teardown.
3. `MetalShaderLibrary`: one decided way to load shaders (runtime compile from
   bundled source; rationale below).
4. Shared helpers extracted or newly built: `PaletteRampLUT` (extracted from
   `Cascade`), `ColorPacking`, `OnsetEnvelope`, `PolylineRibbon`, `FrameRing`.
5. `VisualizerHost` routing: prefer a Metal renderer when one exists for the
   current mode and a Metal device is available; otherwise the existing Canvas
   path, byte-for-byte unchanged.
6. Test scaffolding: `MetalOffscreenRenderer` so Metal modes get snapshot tests
   with the same `assertSnapshot` workflow the Canvas modes use.

## Non-goals

- No mode is converted here (12.7 to 12.10 do that, one mode per phase).
- No Canvas renderer is deleted, ever, in this phase series. Canvas renderers
  remain the fallback when Metal is unavailable (VMs, exotic CI) and the
  reference implementation for visual parity.
- No new visualizer modes (Starfield is 12.11, Nebula is 12.12).
- No new user-facing strings, no Settings changes, no L10n work.
- No compute shaders, no MPS, no offline render pipeline caching.

## Outcome shape

```
Modules/UI/Sources/UI/Visualizers/Metal/
├── MetalVisualizer.swift            # NEW: protocol + MetalSupport.device
├── MetalVisualizerView.swift        # NEW: NSViewRepresentable MTKView host
├── MetalShaderLibrary.swift         # NEW: shader source loading + compile cache
├── PaletteRampLUT.swift             # NEW: LUT extracted from Cascade + MTLTexture
├── ColorPacking.swift               # NEW: Color -> SIMD4<Float> / UInt32 BGRA
├── OnsetEnvelope.swift              # NEW: shared attack/decay envelope
├── PolylineRibbon.swift             # NEW: polyline -> triangle strip expansion
├── FrameRing.swift                  # NEW: triple-buffered per-frame MTLBuffers
└── FrameRateMonitor.swift           # NEW: off-@State frame-rate watchdog

Modules/UI/Sources/UI/Resources/Shaders/
└── (empty in this phase; per-mode .metal files arrive in 12.7+)

Modules/UI/Sources/UI/Visualizers/
├── Cascade.swift                    # refactored onto PaletteRampLUT (no visual change)
└── VisualizerHost.swift             # + Metal branch (returns Canvas for all modes today)
```

## Definitions and contracts

### `MetalVisualizer` protocol

```swift
import MetalKit

/// A visualizer rendered via Metal instead of SwiftUI Canvas.
///
/// Split into `update` (CPU state, fully unit-testable, no GPU required) and
/// `encode` (GPU commands, kept as thin as possible). All methods run on the
/// main actor; MTKView invokes its delegate on the main thread.
/// Palette + a11y flags bundled into one value so initializers and the factory
/// stay within the 5-parameter lint budget (and a future flag touches one type).
public struct MetalRendererConfig: Sendable, Equatable {
    public let palette: VisualizerPalette
    public let reduceMotion: Bool
    public let reduceTransparency: Bool
    public init(palette: VisualizerPalette, reduceMotion: Bool, reduceTransparency: Bool)
}

@MainActor
public protocol MetalVisualizer: AnyObject {
    /// Create pipeline states, persistent textures, and buffers. Throwing here
    /// makes the host fall back to the Canvas renderer for this mode (logged,
    /// never fatal).
    init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        config: MetalRendererConfig
    ) throws

    /// Per-frame CPU work: integrate motion, pack uniforms, write textures.
    /// Mirrors the data flow of `Visualizer.render` minus the drawing.
    func update(
        analysis: Analysis,
        samples: AudioSamples,
        time: TimeInterval,
        drawableSize: CGSize
    )

    /// Encode draw commands for one frame. The host owns the render pass
    /// (clear to opaque black), the command buffer, present, and commit.
    func encode(into encoder: MTLRenderCommandEncoder)

    /// Called by the host after `encode` returns and encoding has ended,
    /// before commit. Renderers that use `FrameRing` call
    /// `ring.release(when: commandBuffer)` here; everyone else takes the
    /// default no-op.
    func didEncode(commandBuffer: MTLCommandBuffer)

    /// Fraction of native drawable resolution to render at (1.0 = native).
    /// Default 1.0 via protocol extension. Nebula (12.12) overrides this for
    /// adaptive scaling; other modes do not.
    var renderScale: CGFloat { get }
}

public extension MetalVisualizer {
    func didEncode(commandBuffer: MTLCommandBuffer) {}
    var renderScale: CGFloat { 1.0 }
}
```

### `MetalSupport`

```swift
@MainActor
enum MetalSupport {
    /// Cached system default device; nil on machines without Metal.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}
```

### `MetalVisualizerFactory`

```swift
@MainActor
enum MetalVisualizerFactory {
    /// True when `mode` has a Metal renderer. 12.6 returns false for every
    /// mode; each conversion phase adds its arm.
    static func supports(_ mode: VisualizerMode) -> Bool { false }

    /// Builds the renderer, or nil (unsupported mode / init threw, logged).
    static func make(
        mode: VisualizerMode,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        config: MetalRendererConfig
    ) -> (any MetalVisualizer)?

    /// Wraps a throwing initializer: logs + returns nil on failure, logs ok on
    /// success. Conversion phases call this from `make`.
    static func instantiate(
        mode: VisualizerMode,
        _ build: () throws -> any MetalVisualizer
    ) -> (any MetalVisualizer)?
}
```

`make` wraps the throwing init in do/catch and logs failures via
`AppLogger.make(.ui)` as `visualizer.metal.init.failed` with the mode and
`String(reflecting: error)`. Returning nil is always safe: the host falls back
to Canvas.

### `VisualizerHost` routing

`rebuildRenderer()` gains a Metal attempt before the Canvas switch:

```swift
self.metalRenderer = nil
if let device = MetalSupport.device,
   !UserDefaults.standard.bool(forKey: "visualizer.forceCanvas"),
   MetalVisualizerFactory.supports(vm.mode) {
    let config = MetalRendererConfig(
        palette: vm.palette, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
    )
    self.metalRenderer = MetalVisualizerFactory.make(
        mode: vm.mode, device: device, pixelFormat: .bgra8Unorm, config: config
    )
}
// Always build the Canvas renderer too (it is the fallback and costs nothing
// until rendered).
```

`body` renders `MetalVisualizerView` when `metalRenderer != nil`, otherwise
the existing `timelineCanvas`. The ZStack black background, performance-toast
overlay, accessibility label, and all `.onChange` rebuild triggers stay
exactly as they are and wrap both branches.

`"visualizer.forceCanvas"` is a debug escape hatch (UserDefaults bool, no UI).
Document it in a comment; it exists so a regression can be A/B-tested live.

### `MetalVisualizerView`

`NSViewRepresentable` wrapping an `MTKView` subclass. Requirements, all of
which exist to dodge a specific known failure mode:

- **Configuration**: `colorPixelFormat = .bgra8Unorm`, `clearColor` opaque
  black, `isPaused = false`, `enableSetNeedsDisplay = false` (continuous),
  `framebufferOnly = true`. Set the layer colorspace to sRGB:
  `(view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)`.
  See the colour-parity gotcha below.
- **Frame pacing**: `preferredFramesPerSecond = vm.effectiveFPS`, re-applied in
  `updateNSView` so the Settings FPS cap and the battery cap keep working.
- **Watchdog**: the coordinator owns a `FrameRateMonitor` (a pure value type)
  and feeds it the present timestamp each frame; on the frame it trips it calls
  `vm.autoSimplify()`. A sustained sub-30 fps Metal mode auto-simplifies to
  Spectrum Bars with the existing toast and Revert button, identical to the
  Canvas path. **Do not route this through the host's `@State`
  `recordFrameTick`** (an early draft did, via an `onFrame` closure): mutating
  `@State` every frame re-evaluates the host `body` (and re-queries the battery
  via `effectiveFPS`) at the display rate, an update storm that starves the
  draw loop and makes the watchdog fire against a renderer that is actually
  fast. Measuring in the coordinator keeps it off the SwiftUI update cycle.
- **Render scale**: `autoResizeDrawable = false`. The MTKView subclass
  overrides `layout()` and sets
  `drawableSize = convertToBacking(bounds.size) * renderer.renderScale`,
  re-checked each frame in `draw(in:)` so a renderer that changes its scale
  takes effect without a resize.
- **Warm-up fade**: the view starts at `alphaValue = 0` over the host's black
  background; after the first successful `commandBuffer.commit()` the delegate
  fades it to 1 over 150 ms (`NSAnimationContext`; skip the animation under
  reduce motion, jump straight to 1). No spinner. This is the phase 12 gotcha
  about the first drawable.
- **Per-frame flow** in `draw(in:)`:
  1. acquire `currentRenderPassDescriptor` / `currentDrawable` / command buffer
     / encoder; return early if any is nil (window miniaturised, display
     asleep) without logging per frame. **Guard before `update()`**: a renderer
     may take a per-frame resource (a `FrameRing` slot) in `update()` and
     release it in `didEncode()`, so a frame skipped after `update()` would
     leak the slot and deadlock the ring. Guarding first keeps update -> encode
     -> didEncode atomic.
  2. read `vm.analysis` / `vm.latestSamples` and call
     `renderer.update(analysis:samples:time:drawableSize:)` with
     `CACurrentMediaTime()` as time,
  3. `renderer.encode(into:)`, end encoding, `renderer.didEncode(commandBuffer:)`,
     present, commit,
  4. on the first presented frame, start the warm-up fade,
  5. feed the present timestamp to the `FrameRateMonitor`.
- **Teardown**: `dismantleNSView` sets `isPaused = true` and `delegate = nil`,
  or the GPU keeps drawing for a closed pane (phase 12 fullscreen open/close
  bug). Verify with the existing fullscreen test procedure.
- **Rebuild semantics**: the host applies `.id(rendererKey)` to
  `MetalVisualizerView` using the same key string `rebuildRenderer()` computes,
  so mode/palette/a11y changes tear the view down and rebuild it. Do not try
  to mutate a live renderer's palette.

### `MetalShaderLibrary`

**Decision: runtime compilation from bundled source, always.** Shaders live as
`.metal` files under `Modules/UI/Sources/UI/Resources/Shaders/` (covered by the
existing `.process("Resources")` rule) and are compiled at renderer init via
`device.makeLibrary(source:options:)`, cached per device in a dictionary keyed
by resource name.

Rationale, documented in code: SwiftPM can in principle compile `.metal`
sources into `default.metallib`, but support differs between `xcodebuild`,
`swift build`, and `swift test`, and this module's test suite runs under
`swift test` (`make test-ui`). One code path that works identically everywhere
beats a faster path that works in three of four contexts. The shaders are
small; compilation is a few milliseconds, once per renderer lifetime.

```swift
@MainActor
enum MetalShaderLibrary {
    /// Loads `Resources/Shaders/<name>.metal` from Bundle.module and compiles
    /// it (cached). Throws MetalShaderError with the resource name and the
    /// compiler diagnostics on failure.
    static func library(named name: String, device: MTLDevice) throws -> MTLLibrary
}
```

If SwiftPM warns about unhandled `.metal` files under `.process`, switch the
declaration to an explicit `.copy("Resources/Shaders")` and note it in the PR.

### `ColorPacking`

Extracted/shared colour conversion (the conversion currently lives inside
`Cascade.blendColors`):

```swift
enum ColorPacking {
    /// sRGB components as gamma-encoded floats (matches what Core Graphics
    /// fills with, which is what colour parity with Canvas requires).
    static func simd(_ color: Color) -> SIMD4<Float>
    /// Packed BGRA byte order (B | G<<8 | R<<16 | A<<24), little-endian,
    /// alpha 255. Matches CGBitmapContext byteOrder32Little premultipliedFirst.
    static func bgra(_ color: Color) -> UInt32
}
```

Implementation detail: `NSColor(color).usingColorSpace(.sRGB)`; return
`.zero` / opaque black on conversion failure (never crash on a weird dynamic
colour).

### `PaletteRampLUT` (extracted from Cascade)

Move `Cascade.buildLUT`, `Cascade.blendColors` (packing part goes to
`ColorPacking`), and the drift-regeneration threshold logic into one shared
type. Canvas `Cascade` is refactored to use it **in this phase**, with the
existing Cascade snapshot tests proving zero visual drift.

```swift
struct PaletteRampLUT {
    static let size = 256

    private(set) var colors: [UInt32]      // BGRA packed, index 0 darkest

    init(palette: VisualizerPalette)

    /// Rebuilds when needed (first call; drift palette when base hue moved
    /// more than 1/256 cycle, wrap-aware). Returns true when it rebuilt.
    mutating func rebuildIfNeeded(analysis: Analysis, time: TimeInterval) -> Bool

    /// 256 x 1 bgra8Unorm texture of the current colors.
    func makeTexture(device: MTLDevice) -> MTLTexture?
    /// Re-uploads colors into an existing texture (drift regeneration).
    func upload(into texture: MTLTexture)
}
```

Behavioural contract (verbatim from Cascade, do not re-derive): 256 entries
interpolated linearly in sRGB from the 8 `PaletteResolver.rampStops`; drift
base hue is `fract(time / 90 + 0.25 * centroid)`; rebuild when wrap-aware hue
distance exceeds 1/256; static palettes build exactly once.

### `OnsetEnvelope`

The attack/decay envelope both Starfield (12.11) and Nebula (12.12) need, and
the place the `frameIndex` edge-detection idiom is implemented once:

```swift
/// Normalised 0...1 envelope: jumps to 1.0 on a new onset, decays
/// exponentially. Re-triggering resets to 1.0 (clamp, no stacking).
struct OnsetEnvelope {
    let tau: TimeInterval                  // decay time constant, seconds

    private(set) var value: Double = 0
    private var lastFrameIndex: UInt64 = 0
    private var lastTime: TimeInterval?

    /// Call once per render. Internally: decay by exp(-dt / tau) with dt
    /// clamped to 0...0.1 s, then if `analysis.frameIndex` is new AND
    /// `analysis.onset`, set value = 1.0 and remember the frameIndex so the
    /// same 43 Hz analysis frame seen by multiple 60 Hz renders fires once.
    mutating func update(analysis: Analysis, time: TimeInterval)
}
```

### `PolylineRibbon`

Metal has no line width: line primitives are 1-pixel hairlines. Every stroked
path from the Canvas renderers (oscilloscope trace, Halo rim) must become a
triangle strip. This helper is where that geometry lives, CPU-side and
unit-tested:

```swift
enum PolylineRibbon {
    /// Expands a polyline into a triangle strip of width `width`, centred on
    /// the line. Per point: two vertices offset along the averaged normal of
    /// the adjacent segments (miter length clamped to 2 * width to avoid
    /// spikes at sharp angles). `closed: true` wraps the strip (last pair
    /// repeats the first pair) for loops like the Halo rim.
    /// Open polylines get butt caps (no caps geometry); at the 1.5...2 pt
    /// widths the visualizers use, the difference from round caps is below
    /// snapshot tolerance.
    static func strip(
        points: [SIMD2<Float>],
        width: Float,
        closed: Bool
    ) -> [SIMD2<Float>]
}
```

### `FrameRing`

CPU-written, GPU-read per-frame buffers race without synchronisation: the CPU
writes frame N+1's data while the GPU still reads frame N's. Standard triple
buffering, implemented once:

```swift
/// A ring of `slots` MTLBuffers guarded by a DispatchSemaphore. `acquire()`
/// blocks until a slot's previous GPU work finished; `release(when:)`
/// registers the signal on the command buffer's completion handler.
final class FrameRing {
    init?(device: MTLDevice, bytesPerSlot: Int, slots: Int = 3)

    /// Wait + return the next slot. Call exactly once per frame, before
    /// writing vertex/uniform data.
    func acquire() -> MTLBuffer

    /// Signal the slot when `commandBuffer` completes. Call exactly once per
    /// frame, before commit. The completion handler is `@Sendable` and only
    /// touches the semaphore (thread-safe by design); do not capture renderer
    /// state in it.
    func release(when commandBuffer: MTLCommandBuffer)
}
```

Buffers use `storageModeShared` (Apple Silicon unified memory; this app is
arm64-only).

### `MetalOffscreenRenderer` (test target only)

Lives in `Modules/UI/Tests/UITests/SnapshotTests/`:

```swift
/// Renders one frame of a MetalVisualizer to an offscreen bgra8Unorm texture
/// and returns it as NSImage for assertSnapshot(as: .image). Returns nil when
/// no Metal device exists; callers skip the test in that case.
@MainActor
enum MetalOffscreenRenderer {
    static func render(
        _ renderer: any MetalVisualizer,
        size: CGSize,                      // pixels
        analysis: Analysis,
        samples: AudioSamples,
        time: TimeInterval
    ) -> NSImage?
}
```

Implementation: manual `MTLRenderPassDescriptor` over a fresh texture (no
MTKView), clear to opaque black, `renderer.update(...)` then
`renderer.encode(...)`, `commandBuffer.waitUntilCompleted()`, `getBytes` into a
buffer, build a CGImage (note BGRA byte order + sRGB colorspace), wrap in
NSImage. Metal snapshot suites copy the existing pattern: `.serialized`,
disabled when `CI` env var is set, precision 0.95 / perceptualPrecision 0.98.

## Implementation plan

1. Protocol, `MetalSupport`, `MetalShaderLibrary` + a trivial inline test
   shader string proving compile works under `swift test`. Unit tests for the
   library cache and the error path. Commit.
2. `ColorPacking` + `PaletteRampLUT` extraction; refactor Canvas `Cascade` onto
   them; run the existing Cascade unit + snapshot suites unchanged (this is
   the parity proof). Commit.
3. `OnsetEnvelope`, `PolylineRibbon`, `FrameRing` with full unit tests (no GPU
   needed for any of them; FrameRing's semaphore logic is testable with a
   mock-free real device guarded by availability, or by extracting the index
   arithmetic). Commit.
4. `MetalVisualizerView` + factory + `VisualizerHost` routing (factory returns
   nil for everything, so behaviour is unchanged); `MetalOffscreenRenderer` +
   one smoke test that clears a texture and asserts non-nil image. Commit.

## Context7 lookups

- `use context7 MTKView NSViewRepresentable SwiftUI macOS delegate draw`
- `use context7 MTLDevice makeLibrary source runtime compilation options`
- `use context7 Metal triple buffering semaphore in flight frames`
- `use context7 MTKView autoResizeDrawable drawableSize preferredFramesPerSecond`
- `use context7 CAMetalLayer colorspace sRGB pixel format bgra8Unorm`
- `use context7 MTLTexture getBytes CGImage byte order BGRA`

## Dependencies

None new. `Metal` and `MetalKit` are system frameworks; no `Package.swift`
dependency changes. (If the `.metal`-as-resource warning forces it, a
`.copy("Resources/Shaders")` resource rule is the only manifest edit.)

## Test plan

All CPU-side, no GPU required except where noted:

- **ShaderLibrary**: compiling a valid source string yields a library exposing
  its functions; an invalid source throws an error containing the diagnostics;
  the cache returns the identical instance on the second call. (Requires a
  device; skip via `guard let device = MetalSupport.device else return`.)
- **ColorPacking**: `.white` packs to 0xFFFFFFFF; pure red packs B=0 G=0 R=255;
  `simd` of a known sRGB colour round-trips within 1/255 per channel.
- **PaletteRampLUT**: byte-identical output to the pre-refactor
  `Cascade.buildLUT` for all six palettes at a fixed (analysis, time); drift
  rebuild threshold honoured (no rebuild at +0.001 hue, rebuild at +0.01);
  static palettes never rebuild after the first call. Existing Cascade
  snapshots unchanged.
- **OnsetEnvelope**: onset sets value to 1.0; after 1 tau it is within 5% of
  1/e; the same frameIndex seen three times triggers once; a new frameIndex
  without onset does not trigger; two onsets 0.1 s apart re-set to 1.0 (never
  above 1.0); dt clamp survives a 5 s gap.
- **PolylineRibbon**: a horizontal 2-point line of width 2 yields 4 vertices
  offset exactly +-1 vertically; vertex count = 2 * points (+2 when closed); a
  90 degree corner's miter length is clamped; degenerate input (0 or 1 point)
  returns empty.
- **FrameRing**: acquiring `slots` times without release does not deadlock the
  test (verify via the index arithmetic extracted as a pure function, not by
  blocking the test thread).
- **Host routing**: with the factory stubbed to return nil, the Canvas path
  renders (existing snapshot tests are the proof, unchanged). A source
  convention test asserts `VisualizerHost` consults
  `MetalVisualizerFactory.supports` and the `visualizer.forceCanvas` default.
- **Offscreen smoke** (GPU, skipped when no device): a do-nothing renderer
  (encode draws nothing) produces an all-black non-nil NSImage at 64 x 64.

## Acceptance criteria

- [ ] All six helpers exist with the documented APIs and tests.
- [ ] Canvas `Cascade` runs on `PaletteRampLUT`; its unit and snapshot suites
      pass without re-recording.
- [ ] `VisualizerHost` routes through the factory; with no conversions landed,
      every existing snapshot and unit test passes unchanged.
- [ ] Shader runtime compilation proven under `swift test` (not only Xcode).
- [ ] No new user-facing strings (`make pseudolocale` untouched).
- [ ] `make lint && make test-ui && make test-coverage` green.
- [ ] No em dashes anywhere (docs, code comments, commit messages).

## Gotchas

- **Colour parity is the trap that wastes a day.** Core Graphics fills with
  gamma-encoded sRGB values. If the Metal pipeline uses `.bgra8Unorm_srgb`,
  the hardware applies a linear-to-sRGB encode on write and everything renders
  washed out relative to Canvas. The recipe in this spec (plain
  `.bgra8Unorm`, layer colorspace sRGB, shaders treat colour values as
  already-encoded sRGB and do simple arithmetic on them, exactly like Core
  Graphics does) is chosen for parity, not purity. Do not "fix" it to be
  linear-correct; that guarantees visible drift from the Canvas renderers.
- **MSL struct alignment.** Never use `SIMD3<Float>`/`float3` in a uniform
  struct (16-byte alignment surprises). Allowed types: `Float`, `UInt32`,
  `SIMD2<Float>`, `SIMD4<Float>`. Mirror every Swift uniform struct manually
  in MSL and add a unit test asserting `MemoryLayout<T>.stride` equals the
  documented byte count. A silent mismatch renders as "the music does
  nothing", which looks like a design bug, not a memory bug.
- **Vertex pulling, not vertex descriptors.** Vertex functions index typed
  buffers by `vertex_id`/`instance_id` (`constant Vertex *verts [[buffer(0)]]`).
  No `MTLVertexDescriptor` anywhere in this phase series; it removes an entire
  class of stride/offset bugs.
- **Metal lines are hairlines.** `.line`/`.lineStrip` primitives ignore any
  notion of width. Every stroke goes through `PolylineRibbon`. If a converted
  mode shows a 1-pixel anaemic line, this is why.
- **MTKView delegate runs on the main thread**, so `@MainActor` renderers work
  without hops, but do not block in `draw(in:)` (no `waitUntilCompleted` in
  the live path; that is for the offscreen test renderer only).
- **The MTKView draws on the main thread, so do not flood that thread with
  SwiftUI updates.** `VisualizerViewModel.analysis` / `latestSamples` are
  deliberately *not* `@Published`: both renderers read them at draw time off
  their own clock (the `TimelineView` tick, the `MTKView` display link), so a
  publish only forces a `VisualizerHost.body` re-evaluation at the tap rate
  (~43x/s each). That storm runs `updateNSView` and an IOKit battery query
  (`effectiveFPS`) per frame and starves the Metal draw loop badly enough that
  the watchdog auto-simplifies a renderer that is actually fast. Symptom: the
  Metal mode holds while paused and dies ~3 s after playback starts. Likewise
  keep `updateNSView` cheap (guard the `preferredFramesPerSecond` reassignment;
  setting it reconfigures the display link).
- **`currentRenderPassDescriptor` can be nil** (window miniaturised, display
  asleep). Return early, silently. Logging per frame floods the ring buffer.
- **Teardown ordering.** `dismantleNSView` must pause before nilling the
  delegate. The fullscreen window and the pane may each host an MTKView
  simultaneously (the tap is reference-counted already); each owns its own
  renderer instance and they must not share `FrameRing`s or textures.
- **Snapshot nondeterminism.** GPU rasterisation differs subtly across GPU
  families and OS versions. Metal snapshots are local-only (the suites are
  already CI-disabled) and use the established 0.95/0.98 precision. Re-record
  with `SNAPSHOT_TESTING_RECORD=all` after intentional changes, and eyeball
  the diff.
- **Coverage.** Keep `encode(into:)` mechanical (bind, draw, repeat); every
  branch and number lives in `update` or a pure helper so the UI module's
  coverage floor survives the GPU-exempt encode paths. This matches the
  exemption phase 12 documented for Metal render paths.

## Handoff

Phases 12.7 to 12.12 each convert or add one mode. They expect: the protocol
and factory exactly as above, `MetalShaderLibrary.library(named:device:)`,
`PaletteRampLUT`, `ColorPacking`, `OnsetEnvelope`, `PolylineRibbon`,
`FrameRing`, `MetalOffscreenRenderer`, and the host routing with the
`visualizer.forceCanvas` escape hatch. Recommended order: 12.7 Oscilloscope
(simplest, proves the ribbon + uniform path), 12.8 Cascade (proves the
texture + LUT path), 12.9 Spectrum Bars (proves instancing), 12.10 Halo,
12.11 Starfield, 12.12 Nebula.
