import AppKit
import AudioEngine
import MetalKit
import simd

// MARK: - CascadeUniforms

/// CPU mirror of the MSL `CascadeUniforms` (same field order, 48 bytes).
struct CascadeUniforms {
    var nowColor: SIMD4<Float>
    var cursorPlusOffset: Float
    var nowLineWidthUV: Float
    var glowAlpha: Float
    var showNowLine: Float
    var pad: SIMD4<Float>
}

// MARK: - MetalCascade

/// Metal port of the Canvas ``Cascade``. The history ring buffer is an
/// `MTLTexture` the fragment shader samples directly, so the per-frame
/// `makeImage()` copy and the two-crop `CGImage` presentation both disappear:
/// the ring wrap is a texture-coordinate wrap and the smooth scroll is a
/// sub-column offset in the sample coordinate.
///
/// Colours are baked into the texture at write time through the shared
/// ``PaletteRampLUT`` (exactly as the Canvas renderer writes its bitmap), which
/// is what preserves the drift palette's "history keeps its original colour"
/// behaviour for free. The Canvas renderer stays the visual-parity reference.
@MainActor
final class MetalCascade: MetalVisualizer {
    // MARK: - Constants (structural ones shared with the Canvas renderer)

    static let columnCount = Cascade.columnCount
    static let bandCount = Cascade.bandCount
    static let lutSize = Cascade.lutSize
    static let columnPeriod = Cascade.columnPeriod
    private static let nowLineWidthPoints: CGFloat = 1
    private static let glowDuration: TimeInterval = 0.15
    private static let glowPeakAlpha: Float = 0.5
    private static let stepInterval: TimeInterval = 1.0

    // MARK: - Configuration

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    var pixelsPerPointOverride: CGFloat?
    private var pixelsPerPoint: CGFloat {
        self.pixelsPerPointOverride ?? (NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - GPU state

    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let historyTexture: MTLTexture
    /// Stepped-mode snapshot target, only allocated under reduce motion.
    private let displayTexture: MTLTexture?
    /// Private queue for the once-a-second stepped blit, only under reduce motion.
    private let blitQueue: MTLCommandQueue?

    // MARK: - CPU state (internal for testing)

    private(set) var cursor = 0
    private(set) var lastFrameIndex: UInt64 = 0
    private(set) var lastColumnTime: TimeInterval = 0
    private(set) var steppedCursor = 0
    private var rampLUT: PaletteRampLUT
    private var stagingColumn: [UInt32]
    private var lastWriteTime: TimeInterval = 0
    private var lastStepTime: TimeInterval?
    private(set) var uniforms = CascadeUniforms(
        nowColor: .zero, cursorPlusOffset: 0, nowLineWidthUV: 0, glowAlpha: 0, showNowLine: 0, pad: .zero
    )

    // MARK: - Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        self.palette = config.palette
        self.reduceMotion = config.reduceMotion
        self.rampLUT = PaletteRampLUT(palette: config.palette)
        self.stagingColumn = [UInt32](repeating: 0xFF00_0000, count: Self.bandCount)

        let library = try MetalShaderLibrary.library(named: "Cascade", device: device)
        guard let vertexFunction = library.makeFunction(name: "cascade_vertex") else {
            throw MetalRendererError.missingFunction(name: "cascade_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "cascade_fragment") else {
            throw MetalRendererError.missingFunction(name: "cascade_fragment")
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
        samplerDescriptor.sAddressMode = .repeat // wrap the ring buffer
        samplerDescriptor.tAddressMode = .clampToEdge // bands do not wrap
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "cascade sampler")
        }
        self.sampler = sampler

        self.historyTexture = try Self.makeHistoryTexture(device: device)
        if config.reduceMotion {
            self.displayTexture = try Self.makeHistoryTexture(device: device)
            guard let queue = device.makeCommandQueue() else {
                throw MetalRendererError.resourceAllocationFailed(reason: "cascade blit queue")
            }
            self.blitQueue = queue
        } else {
            self.displayTexture = nil
            self.blitQueue = nil
        }
    }

    /// A 256 x 32 BGRA texture cleared to opaque black.
    private static func makeHistoryTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.columnCount,
            height: Self.bandCount,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "cascade history texture")
        }
        let cleared = [UInt32](repeating: 0xFF00_0000, count: Self.columnCount * Self.bandCount)
        cleared.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.columnCount, Self.bandCount),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: Self.columnCount * 4
            )
        }
        return texture
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        _ = self.rampLUT.rebuildIfNeeded(analysis: analysis, time: time)

        if analysis.frameIndex != self.lastFrameIndex {
            self.lastFrameIndex = analysis.frameIndex
            self.writeColumn(analysis: analysis, time: time)
            if self.reduceMotion {
                self.stepIfDue(time: time)
            }
        }

        self.packUniforms(analysis: analysis, time: time, drawableSize: drawableSize)
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(self.pipeline)
        // Reduce motion presents the once-a-second snapshot; otherwise the live
        // history, which the shader scrolls smoothly via the sub-column offset.
        let texture = self.reduceMotion ? (self.displayTexture ?? self.historyTexture) : self.historyTexture
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(self.sampler, index: 0)
        var uniforms = self.uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CascadeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - Column write (internal for testing)

    /// Fills `column` with one spectrogram column for `analysis`, BGRA packed,
    /// matching `Cascade.writeColumn` exactly: bass (band 0) at the bottom row,
    /// treble (band 31) at the top, onset frames marked at the top and bottom two
    /// rows. Static and buffer-in-out so the live path is allocation-free and the
    /// logic stays unit-testable without a GPU.
    static func fillColumn(_ column: inout [UInt32], analysis: Analysis, ramp: [UInt32]) {
        for band in 0 ..< self.bandCount {
            let magnitude = band < analysis.bands.count ? analysis.bands[band] : 0
            let lutIndex = min(Self.lutSize - 1, Int(magnitude * Float(Self.lutSize - 1)))
            let row = Self.bandCount - 1 - band
            column[row] = ramp[lutIndex]
        }
        if analysis.onset {
            let full = ramp[Self.lutSize - 1]
            column[0] = full
            column[1] = full
            column[Self.bandCount - 2] = full
            column[Self.bandCount - 1] = full
        }
    }

    private func writeColumn(analysis: Analysis, time: TimeInterval) {
        Self.fillColumn(&self.stagingColumn, analysis: analysis, ramp: self.rampLUT.colors)
        self.stagingColumn.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // bytesPerRow is 4 (one pixel per row) for a 1-wide region, NOT
            // columnCount * 4; the wrong value smears columns diagonally.
            self.historyTexture.replace(
                region: MTLRegionMake2D(self.cursor, 0, 1, Self.bandCount),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: 4
            )
        }
        self.cursor = (self.cursor + 1) % Self.columnCount
        self.lastColumnTime = time
        self.lastWriteTime = time
    }

    // MARK: - Reduce-motion stepping

    private func stepIfDue(time: TimeInterval) {
        let sinceStep = self.lastStepTime.map { time - $0 } ?? Self.stepInterval
        guard sinceStep >= Self.stepInterval else { return }
        self.blitHistoryToDisplay()
        self.steppedCursor = self.cursor
        self.lastStepTime = time
    }

    private func blitHistoryToDisplay() {
        guard
            let display = self.displayTexture,
            let queue = self.blitQueue,
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: self.historyTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: Self.columnCount, height: Self.bandCount, depth: 1),
            to: display,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
    }

    // MARK: - Uniforms (internal for testing)

    func packUniforms(analysis: Analysis, time: TimeInterval, drawableSize: CGSize) {
        let nowColor = ColorPacking.simd(PaletteResolver.color(
            palette: self.palette, position: 1, magnitude: 1, analysis: analysis, time: time
        ))
        let width = Float(max(1, drawableSize.width))
        let nowLineWidthUV = Float(Self.nowLineWidthPoints * self.pixelsPerPoint) / width

        if self.reduceMotion {
            self.uniforms = CascadeUniforms(
                nowColor: nowColor,
                cursorPlusOffset: Float(self.steppedCursor),
                nowLineWidthUV: nowLineWidthUV,
                glowAlpha: 0,
                showNowLine: 0,
                pad: .zero
            )
            return
        }

        let subColumnFraction = self.lastColumnTime > 0
            ? Float(min(max((time - self.lastColumnTime) / Self.columnPeriod, 0), 1))
            : 0
        let age = time - self.lastWriteTime
        let glowAlpha = (self.lastWriteTime > 0 && age < Self.glowDuration)
            ? Float(1 - age / Self.glowDuration) * Self.glowPeakAlpha
            : 0
        self.uniforms = CascadeUniforms(
            nowColor: nowColor,
            cursorPlusOffset: Float(self.cursor) + subColumnFraction,
            nowLineWidthUV: nowLineWidthUV,
            glowAlpha: glowAlpha,
            showNowLine: 1,
            pad: .zero
        )
    }
}
