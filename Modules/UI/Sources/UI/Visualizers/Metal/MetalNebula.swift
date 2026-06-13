import AudioEngine
import MetalKit
import Observability
import simd

// MARK: - MetalNebula

/// The Nebula visualizer: a full-screen domain-warped fBm gas cloud with four
/// drifting wisps, onset pressure waves, and palette-LUT colouring, all driven by
/// the live audio analysis. The first Metal-only mode (no Canvas twin), so the
/// host substitutes Spectrum Bars when Metal is unavailable or Reduce Motion is on.
///
/// All audio-reactive work lives in the pure ``NebulaState`` and the shader is a
/// function of the packed ``NebulaUniforms``; this class only owns the pipeline,
/// the palette LUT texture, and the once-per-frame `update`/`encode` glue. It
/// renders at native resolution (the default ``MetalVisualizer/renderScale``);
/// the host's frame-rate watchdog auto-simplifies to Spectrum Bars if a slow GPU
/// ever cannot keep up.
@MainActor
final class MetalNebula: MetalVisualizer {
    // MARK: - Configuration

    private let palette: VisualizerPalette
    private static let log = AppLogger.make(.ui)

    // MARK: - GPU state

    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let lutTexture: MTLTexture

    // MARK: - CPU state (internal for testing)

    private(set) var state = NebulaState()
    private var rampLUT: PaletteRampLUT
    private(set) var uniforms = NebulaUniforms(
        drawableSize: .zero,
        flowTime: 0,
        warpAmp: NebulaState.warpAmpBase,
        exposure: 1,
        onsetPulse: 0,
        centroidTint: 0,
        loudestWisp: 0,
        wisp0: .zero,
        wisp1: .zero,
        wisp2: .zero,
        wisp3: .zero,
        wispStrengths: .zero,
        wispRadii: .zero
    )

    // MARK: - Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        self.palette = config.palette
        self.rampLUT = PaletteRampLUT(palette: config.palette)

        let library = try MetalShaderLibrary.library(named: "Nebula", device: device)
        guard let vertexFunction = library.makeFunction(name: "nebula_vertex") else {
            throw MetalRendererError.missingFunction(name: "nebula_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "nebula_fragment") else {
            throw MetalRendererError.missingFunction(name: "nebula_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(reason: String(reflecting: error))
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "nebula LUT sampler")
        }
        self.sampler = sampler

        // Build the LUT once at the silent frame so the texture exists before the
        // first update; drift palettes regenerate it as their base hue moves.
        _ = self.rampLUT.rebuildIfNeeded(analysis: .silent, time: 0)
        guard let texture = self.rampLUT.makeTexture(device: device) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "nebula LUT texture")
        }
        self.lutTexture = texture

        Self.log.info("visualizer.nebula.init", ["palette": config.palette.rawValue])
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        if self.rampLUT.rebuildIfNeeded(analysis: analysis, time: time) {
            self.rampLUT.upload(into: self.lutTexture)
        }
        self.uniforms = self.state.update(analysis: analysis, time: time, drawableSize: drawableSize)
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(self.pipeline)
        encoder.setFragmentTexture(self.lutTexture, index: 0)
        encoder.setFragmentSamplerState(self.sampler, index: 0)
        var uniforms = self.uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NebulaUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - Test seam

    /// Pins the uniforms directly for deterministic snapshots, bypassing live
    /// integration. The snapshot suite packs a fixed-`flowTime`/fixed-envelope
    /// frame through ``NebulaState/pack(analysis:drawableSize:)`` and installs it
    /// here, so the GPU output depends on nothing but the fixed inputs.
    func setUniformsForTesting(_ uniforms: NebulaUniforms) {
        self.uniforms = uniforms
    }
}
