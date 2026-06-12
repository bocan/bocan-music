import AppKit
import AudioEngine
import MetalKit
import simd

// MARK: - OscilloscopeUniforms

/// CPU mirror of the MSL `OscilloscopeUniforms` (same field order, 32 bytes).
struct OscilloscopeUniforms {
    var traceColor: SIMD4<Float>
    var lineColor: SIMD4<Float>
}

// MARK: - MetalOscilloscope

/// Metal port of the Canvas ``Oscilloscope``. Same geometry and colours, drawn as
/// triangle-strip ribbons (Metal has no line width) instead of stroked paths.
///
/// All geometry is computed on the CPU in `update` (pixel space, then converted
/// to NDC) and written into a triple-buffered ring; `encode` just binds and
/// draws. The Canvas renderer remains the visual-parity reference.
@MainActor
final class MetalOscilloscope: MetalVisualizer {
    // MARK: - Constants

    /// Buffer is sized for the worst-case trace point count. The Canvas
    /// downsampling keeps at most ~1023 points (the integer-division quirk lets
    /// counts just under 1024 through ungrouped); 1100 leaves headroom.
    static let maxPoints = 1100
    /// Open-ribbon vertices (2 per point) plus the 4-vertex centre-line strip.
    static let maxVertices = maxPoints * 2 + 4
    private static let traceWidthPoints: CGFloat = 1.5
    private static let lineWidthPoints: CGFloat = 0.5
    private static let lineColorAlpha: Float = 0.15
    private static let waveformAmplitude: Float = 0.9

    // MARK: - Configuration

    let variant: OscilloscopeVariant
    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    /// Backing scale used to convert point widths to pixels. A test seam lets
    /// snapshots render at scale 1 so references are resolution-independent.
    var pixelsPerPointOverride: CGFloat?
    private var pixelsPerPoint: CGFloat {
        self.pixelsPerPointOverride ?? (NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - GPU state

    private let pipeline: MTLRenderPipelineState
    private let frameRing: FrameRing

    // MARK: - Per-frame state (internal for testing)

    private(set) var uniforms = OscilloscopeUniforms(traceColor: .zero, lineColor: .zero)
    private(set) var traceVertexCount = 0
    private(set) var lineVertexCount = 0
    private var currentBuffer: MTLBuffer?
    /// Under reduce motion, the first non-empty sample buffer is frozen and
    /// re-rendered every frame (matching the Canvas renderer's `lastSamples`).
    private var frozenSamples: AudioSamples?

    // MARK: - Init

    convenience init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        try self.init(device: device, pixelFormat: pixelFormat, config: config, variant: .waveform)
    }

    init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        config: MetalRendererConfig,
        variant: OscilloscopeVariant
    ) throws {
        self.variant = variant
        self.palette = config.palette
        self.reduceMotion = config.reduceMotion

        let library = try MetalShaderLibrary.library(named: "Oscilloscope", device: device)
        guard let vertexFunction = library.makeFunction(name: "oscilloscope_vertex") else {
            throw MetalRendererError.missingFunction(name: "oscilloscope_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "oscilloscope_fragment") else {
            throw MetalRendererError.missingFunction(name: "oscilloscope_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        // Standard alpha blending for the 15%-opacity centre line over the trace.
        let attachment = descriptor.colorAttachments[0]
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .sourceAlpha
        attachment?.sourceAlphaBlendFactor = .sourceAlpha
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(reason: String(reflecting: error))
        }

        let bytesPerSlot = Self.maxVertices * MemoryLayout<SIMD2<Float>>.stride
        guard let ring = FrameRing(device: device, bytesPerSlot: bytesPerSlot) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "oscilloscope frame ring")
        }
        self.frameRing = ring
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        let traceColor = ColorPacking.simd(PaletteResolver.color(
            palette: self.palette, position: 0, magnitude: 1, analysis: analysis, time: time
        ))
        var lineColor = traceColor
        lineColor.w = traceColor.w * Self.lineColorAlpha
        self.uniforms = OscilloscopeUniforms(traceColor: traceColor, lineColor: lineColor)

        let active = self.resolveActiveSamples(samples)
        let geometry = Self.vertices(
            samples: active,
            variant: self.variant,
            pixelsPerPoint: Float(self.pixelsPerPoint),
            drawableSize: drawableSize
        )
        self.traceVertexCount = geometry.trace.count
        self.lineVertexCount = geometry.line.count

        // Acquire exactly once per frame; released in didEncode. Always acquire
        // (even with zero vertices) so acquire/release stay balanced.
        let buffer = self.frameRing.acquire()
        self.currentBuffer = buffer
        let combined = geometry.trace + geometry.line
        guard !combined.isEmpty else { return }
        combined.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count <= buffer.length else { return }
            buffer.contents().copyMemory(from: base, byteCount: raw.count)
        }
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        guard let buffer = self.currentBuffer else { return }
        encoder.setRenderPipelineState(self.pipeline)
        var uniforms = self.uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OscilloscopeUniforms>.stride, index: 1)

        let stride = MemoryLayout<SIMD2<Float>>.stride
        if self.traceVertexCount > 0 {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var selector: UInt32 = 0
            encoder.setVertexBytes(&selector, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: self.traceVertexCount)
        }
        if self.lineVertexCount > 0 {
            // Bind the same buffer offset to the centre-line region so its
            // vertex_ids index from 0 (no reliance on vertexStart semantics).
            encoder.setVertexBuffer(buffer, offset: self.traceVertexCount * stride, index: 0)
            var selector: UInt32 = 1
            encoder.setVertexBytes(&selector, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: self.lineVertexCount)
        }
    }

    func didEncode(commandBuffer: MTLCommandBuffer) {
        self.frameRing.release(when: commandBuffer)
    }

    // MARK: - Reduce-motion freeze (internal for testing)

    /// Returns the samples to render: the live buffer normally, or the frozen
    /// first non-empty buffer under reduce motion.
    func resolveActiveSamples(_ samples: AudioSamples) -> AudioSamples {
        guard self.reduceMotion else { return samples }
        if self.frozenSamples == nil, !samples.mono.isEmpty || !samples.left.isEmpty {
            self.frozenSamples = samples
        }
        return self.frozenSamples ?? samples
    }

    // MARK: - Geometry (pure, internal for testing)

    /// Trace and centre-line vertices in NDC for one frame. Pure: no GPU, no
    /// instance state, so the geometry is unit-testable without a device.
    static func vertices(
        samples: AudioSamples,
        variant: OscilloscopeVariant,
        pixelsPerPoint: Float,
        drawableSize: CGSize
    ) -> (trace: [SIMD2<Float>], line: [SIMD2<Float>]) {
        let points: [SIMD2<Float>] = switch variant {
        case .waveform:
            Self.waveformPoints(mono: samples.mono, drawableSize: drawableSize)

        case .lissajous:
            Self.lissajousPoints(left: samples.left, right: samples.right, drawableSize: drawableSize)
        }

        let traceWidth = Float(Self.traceWidthPoints) * pixelsPerPoint
        let tracePixel = PolylineRibbon.strip(points: points, width: traceWidth, closed: false)
        let trace = tracePixel.map { Self.toNDC($0, drawableSize: drawableSize) }

        var line = [SIMD2<Float>]()
        // The centre line belongs to the waveform variant only, and only when
        // there is a trace to underlay.
        if variant == .waveform, points.count >= 2 {
            let midY = Float(drawableSize.height) / 2
            let linePoints = [SIMD2<Float>(0, midY), SIMD2(Float(drawableSize.width), midY)]
            let lineWidth = Float(Self.lineWidthPoints) * pixelsPerPoint
            let linePixel = PolylineRibbon.strip(points: linePoints, width: lineWidth, closed: false)
            line = linePixel.map { Self.toNDC($0, drawableSize: drawableSize) }
        }
        return (trace, line)
    }

    /// Downsampled waveform points in pixel space (y grows downward, Canvas
    /// orientation). Matches `Oscilloscope.renderWaveform` exactly.
    static func waveformPoints(mono: [Float], drawableSize: CGSize) -> [SIMD2<Float>] {
        guard mono.count >= 2 else { return [] }
        let targetPoints = min(512, mono.count)
        let step = max(1, mono.count / targetPoints)
        let width = Float(drawableSize.width)
        let midY = Float(drawableSize.height) / 2
        var points = [SIMD2<Float>]()
        for index in stride(from: 0, to: mono.count, by: step) {
            let x = width * Float(index) / Float(mono.count)
            let y = midY - mono[index] * midY * Self.waveformAmplitude
            points.append(SIMD2(x, y))
        }
        return points
    }

    /// Downsampled Lissajous (XY) points in pixel space. Matches
    /// `Oscilloscope.renderLissajous` exactly.
    static func lissajousPoints(left: [Float], right: [Float], drawableSize: CGSize) -> [SIMD2<Float>] {
        let count = min(left.count, right.count)
        guard count >= 2 else { return [] }
        let targetPoints = min(512, count)
        let step = max(1, count / targetPoints)
        let centerX = Float(drawableSize.width) / 2
        let centerY = Float(drawableSize.height) / 2
        let scale = min(centerX, centerY) * Self.waveformAmplitude
        var points = [SIMD2<Float>]()
        for index in stride(from: 0, to: count, by: step) {
            let x = centerX + left[index] * scale
            let y = centerY - right[index] * scale
            points.append(SIMD2(x, y))
        }
        return points
    }

    /// Converts a pixel-space point (y down) to normalised device coordinates
    /// (y up). The single y-flip for the whole pipeline lives here.
    static func toNDC(_ pixel: SIMD2<Float>, drawableSize: CGSize) -> SIMD2<Float> {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let ndcX = width > 0 ? pixel.x / width * 2 - 1 : -1
        let ndcY = height > 0 ? 1 - pixel.y / height * 2 : 1
        return SIMD2(ndcX, ndcY)
    }
}
