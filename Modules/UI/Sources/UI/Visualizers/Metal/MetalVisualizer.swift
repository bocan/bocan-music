import AudioEngine
import MetalKit
import Observability

// MARK: - MetalRendererConfig

/// The rendering configuration shared by every Metal renderer: the active
/// palette and the two accessibility flags.
///
/// Bundled into one value so renderer initializers and the factory stay within
/// the parameter-count budget, and so adding a future flag touches one type
/// rather than every signature.
public struct MetalRendererConfig: Sendable, Equatable {
    /// The active colour palette.
    public let palette: VisualizerPalette
    /// Whether the system or per-app reduce-motion preference is active.
    public let reduceMotion: Bool
    /// Whether the reduce-transparency preference is active.
    public let reduceTransparency: Bool

    /// Creates a configuration from the palette and accessibility flags.
    public init(palette: VisualizerPalette, reduceMotion: Bool, reduceTransparency: Bool) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }
}

// MARK: - MetalVisualizer

/// A visualizer rendered via Metal instead of SwiftUI Canvas.
///
/// Split into `update` (CPU state, fully unit-testable, no GPU required) and
/// `encode` (GPU commands, kept as thin as possible) so that every audio-driven
/// number lives in testable CPU code and the GPU path stays mechanical. All
/// methods run on the main actor; `MTKView` invokes its delegate on the main
/// thread, so a `@MainActor` renderer needs no hops.
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
    /// Mirrors the data flow of ``Visualizer/render(into:size:samples:analysis:time:)``
    /// minus the drawing. `drawableSize` is in pixels.
    func update(
        analysis: Analysis,
        samples: AudioSamples,
        time: TimeInterval,
        drawableSize: CGSize
    )

    /// Encode draw commands for one frame. The host owns the render pass (clear
    /// to opaque black), the command buffer, present, and commit.
    func encode(into encoder: MTLRenderCommandEncoder)

    /// Called by the host after `encode` returns and encoding has ended, before
    /// commit. Renderers that use ``FrameRing`` call `ring.release(when:)` here;
    /// everyone else takes the default no-op.
    func didEncode(commandBuffer: MTLCommandBuffer)

    /// Fraction of native drawable resolution to render at (1.0 = native).
    /// Default 1.0 via protocol extension. Adaptive modes override this; the
    /// host re-reads it every frame.
    var renderScale: CGFloat { get }
}

/// Default implementations for the optional hooks.
public extension MetalVisualizer {
    /// Default no-op: renderers that do not use ``FrameRing`` need no post-encode hook.
    func didEncode(commandBuffer: MTLCommandBuffer) {}

    /// Default native resolution. Adaptive modes override this.
    var renderScale: CGFloat {
        1.0
    }
}

// MARK: - MetalSupport

/// Process-wide Metal capability probe.
@MainActor
enum MetalSupport {
    /// Cached system default device; `nil` on machines without Metal (some VMs,
    /// exotic CI). Logged once on first access so the diagnostics show whether
    /// the GPU path is even available on this machine.
    static let device: MTLDevice? = {
        let log = AppLogger.make(.ui)
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.notice("visualizer.metal.device.unavailable")
            return nil
        }
        log.info("visualizer.metal.device.available", [
            "name": device.name,
            "unifiedMemory": device.hasUnifiedMemory,
        ])
        return device
    }()
}

// MARK: - MetalVisualizerFactory

/// Builds the Metal renderer for a mode when one exists. The host consults this
/// before falling back to the Canvas renderer.
@MainActor
enum MetalVisualizerFactory {
    private static let log = AppLogger.make(.ui)

    /// True when `mode` has a Metal renderer. Foundations phase: false for every
    /// mode. Each conversion phase (12.7 onward) flips its own arm.
    static func supports(_ mode: VisualizerMode) -> Bool {
        switch mode {
        case .oscilloscope, .cascade, .spectrumBars, .halo:
            true

        // Conversion phases add `case .<mode>: true` here.
        default:
            false
        }
    }

    /// Builds the renderer for `mode`, or `nil` when the mode has no Metal
    /// renderer yet or its initializer threw (logged). Returning `nil` is always
    /// safe: the host falls back to Canvas.
    static func make(
        mode: VisualizerMode,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        config: MetalRendererConfig
    ) -> (any MetalVisualizer)? {
        // Each arm forwards to `instantiate(mode:_:)` so a failed pipeline build
        // logs and falls back to Canvas instead of crashing.
        switch mode {
        case .oscilloscope:
            self.instantiate(mode: mode) {
                try MetalOscilloscope(device: device, pixelFormat: pixelFormat, config: config)
            }

        case .cascade:
            self.instantiate(mode: mode) {
                try MetalCascade(device: device, pixelFormat: pixelFormat, config: config)
            }

        case .spectrumBars:
            self.instantiate(mode: mode) {
                try MetalSpectrumBars(device: device, pixelFormat: pixelFormat, config: config)
            }

        case .halo:
            self.instantiate(mode: mode) {
                try MetalHalo(device: device, pixelFormat: pixelFormat, config: config)
            }

        default:
            nil
        }
    }

    /// Wraps a throwing renderer initializer: returns the renderer on success and
    /// `nil` on failure, logging either outcome. Conversion phases call this from
    /// ``make(mode:device:pixelFormat:palette:reduceMotion:reduceTransparency:)``.
    static func instantiate(
        mode: VisualizerMode,
        _ build: () throws -> any MetalVisualizer
    ) -> (any MetalVisualizer)? {
        do {
            let renderer = try build()
            self.log.debug("visualizer.metal.init.ok", ["mode": mode.rawValue])
            return renderer
        } catch {
            self.log.error("visualizer.metal.init.failed", [
                "mode": mode.rawValue,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }
}
