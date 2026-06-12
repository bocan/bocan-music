import AppKit
import AudioEngine
import MetalKit
import simd

// MARK: - BarInstance

/// CPU mirror of the MSL `BarInstance`. Stride is 48 (36 bytes of fields rounded
/// up to the 16-byte `SIMD4` alignment), asserted in the tests.
struct BarInstance {
    var rectMin: SIMD2<Float>
    var rectMax: SIMD2<Float>
    var color: SIMD4<Float>
    var cornerRadius: Float
}

// MARK: - PeakHoldState

/// The peak-hold marker physics, ported verbatim from the Canvas `SpectrumBars`.
///
/// **Frame-based, not dt-based, on purpose.** One physics step runs per rendered
/// frame, so peaks fall faster at 120 fps than at 30. That is the existing
/// behaviour; converting it to dt-based would change the look and break the
/// golden parity test. A pure value type so the trajectory is testable without a
/// GPU.
struct PeakHoldState {
    static let gravity: Float = 0.004
    static let holdFrames = 30

    private(set) var hold: [Float]
    private var velocity: [Float]
    private var counter: [Int]

    init(count: Int) {
        self.hold = [Float](repeating: 0, count: count)
        self.velocity = [Float](repeating: 0, count: count)
        self.counter = [Int](repeating: 0, count: count)
    }

    /// Advances every band one frame against the current magnitudes.
    mutating func step(magnitudes: [Float]) {
        for index in self.hold.indices where index < magnitudes.count {
            let magnitude = magnitudes[index]
            if magnitude >= self.hold[index] {
                self.hold[index] = magnitude
                self.velocity[index] = 0
                self.counter[index] = Self.holdFrames
            } else if self.counter[index] > 0 {
                self.counter[index] -= 1
            } else {
                self.velocity[index] += Self.gravity
                self.hold[index] = max(0, self.hold[index] - self.velocity[index])
            }
        }
    }
}

// MARK: - MetalSpectrumBars

/// Metal port of the Canvas ``SpectrumBars`` using instanced rendering: 32 bar
/// instances and (when shown) 32 peak-marker instances drawn in one call. Each
/// instance is a rounded-rectangle SDF in the fragment shader, which matches
/// Core Graphics' antialiased rounded-rect fills. The Canvas renderer stays the
/// visual-parity reference.
@MainActor
final class MetalSpectrumBars: MetalVisualizer {
    // MARK: - Constants (mirrored from the Canvas renderer)

    static let bandCount = FFTAnalyzer.bandCount
    private static let barSpacingPoints: Float = 2
    private static let headroomPoints: Float = 4
    private static let maxCornerRadiusPoints: Float = 3
    private static let peakHeightPoints: Float = 2
    private static let peakOffsetPoints: Float = 3
    private static let peakOpacity: Float = 0.9
    private static let reduceMotionBarOpacity: Float = 0.5

    // MARK: - Configuration

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    var pixelsPerPointOverride: CGFloat?
    private var pixelsPerPoint: CGFloat {
        self.pixelsPerPointOverride ?? (NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - GPU state

    private let pipeline: MTLRenderPipelineState
    private let frameRing: FrameRing

    // MARK: - CPU state (internal for testing)

    private(set) var peaks = PeakHoldState(count: bandCount)
    private(set) var instances = [BarInstance]()
    private(set) var instanceCount = 0
    private var currentBuffer: MTLBuffer?
    private var drawableSize: SIMD2<Float> = .zero

    // MARK: - Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        self.palette = config.palette
        self.reduceMotion = config.reduceMotion
        self.reduceTransparency = config.reduceTransparency
        self.instances.reserveCapacity(Self.bandCount * 2)

        let library = try MetalShaderLibrary.library(named: "SpectrumBars", device: device)
        guard let vertexFunction = library.makeFunction(name: "spectrum_vertex") else {
            throw MetalRendererError.missingFunction(name: "spectrum_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "spectrum_fragment") else {
            throw MetalRendererError.missingFunction(name: "spectrum_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
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

        let bytesPerSlot = Self.bandCount * 2 * MemoryLayout<BarInstance>.stride
        guard let ring = FrameRing(device: device, bytesPerSlot: bytesPerSlot) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "spectrum bars frame ring")
        }
        self.frameRing = ring
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        self.drawableSize = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        self.instanceCount = self.buildInstances(analysis: analysis, time: time, drawableSize: drawableSize)

        let buffer = self.frameRing.acquire()
        self.currentBuffer = buffer
        guard self.instanceCount > 0 else { return }
        self.instances.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let byteCount = self.instanceCount * MemoryLayout<BarInstance>.stride
            if byteCount <= buffer.length {
                buffer.contents().copyMemory(from: base, byteCount: byteCount)
            }
        }
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        guard let buffer = self.currentBuffer, self.instanceCount > 0 else { return }
        encoder.setRenderPipelineState(self.pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var size = self.drawableSize
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        // Single instanced call: bars (0..<32) first, peaks (32..<64) second, so
        // peaks blend over their bars (primitive order is blend order within a
        // draw call).
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: self.instanceCount
        )
    }

    func didEncode(commandBuffer: MTLCommandBuffer) {
        self.frameRing.release(when: commandBuffer)
    }

    // MARK: - Instance building (internal for testing)

    /// Builds bar instances (and peak markers when shown) into `self.instances`
    /// and returns the count. Runs the peak physics one step per frame.
    func buildInstances(analysis: Analysis, time: TimeInterval, drawableSize: CGSize) -> Int {
        self.instances.removeAll(keepingCapacity: true)
        let bandCount = min(analysis.bands.count, Self.bandCount)
        guard bandCount > 0 else { return 0 }

        let layout = Self.layout(bandCount: bandCount, drawableSize: drawableSize, pixelsPerPoint: Float(self.pixelsPerPoint))
        let barAlpha = self.reduceTransparency ? 1 : (self.reduceMotion ? Self.reduceMotionBarOpacity : 1)

        // Resolve one colour per band (32 lookups), shared by the bar and its peak.
        var bandColors = [SIMD4<Float>]()
        bandColors.reserveCapacity(bandCount)
        for band in 0 ..< bandCount {
            let position = Double(band) / Double(max(Self.bandCount - 1, 1))
            bandColors.append(ColorPacking.simd(PaletteResolver.color(
                palette: self.palette, position: position, magnitude: analysis.bands[band], analysis: analysis, time: time
            )))
        }

        // Bars first.
        for band in 0 ..< bandCount {
            let barHeight = analysis.bands[band] * layout.maxBarHeight
            let top = layout.height - barHeight
            var color = bandColors[band]
            color.w *= barAlpha
            self.instances.append(BarInstance(
                rectMin: SIMD2(layout.x(band), top),
                rectMax: SIMD2(layout.x(band) + layout.barWidth, layout.height),
                color: color,
                cornerRadius: layout.cornerRadius
            ))
        }

        // Peaks second (skipped under reduce motion, matching the Canvas).
        if !self.reduceMotion {
            self.peaks.step(magnitudes: analysis.bands)
            for band in 0 ..< bandCount {
                let peakTop = layout.height - self.peaks.hold[band] * layout.maxBarHeight - layout.peakOffset
                var color = bandColors[band]
                color.w *= Self.peakOpacity
                self.instances.append(BarInstance(
                    rectMin: SIMD2(layout.x(band), peakTop),
                    rectMax: SIMD2(layout.x(band) + layout.barWidth, peakTop + layout.peakHeight),
                    color: color,
                    cornerRadius: 0
                ))
            }
        }
        return self.instances.count
    }

    // MARK: - Layout (pure, internal for testing)

    /// Bar geometry in pixel space, mirroring `SpectrumBars.render` scaled by
    /// `pixelsPerPoint` so the proportions match the Canvas renderer.
    struct Layout {
        let barWidth: Float
        let maxBarHeight: Float
        let cornerRadius: Float
        let height: Float
        let peakHeight: Float
        let peakOffset: Float
        let barSpacing: Float

        func x(_ band: Int) -> Float {
            self.barSpacing + Float(band) * (self.barWidth + self.barSpacing)
        }
    }

    static func layout(bandCount: Int, drawableSize: CGSize, pixelsPerPoint: Float) -> Layout {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let barSpacing = Self.barSpacingPoints * pixelsPerPoint
        let barWidth = (width - barSpacing * Float(bandCount + 1)) / Float(bandCount)
        let maxBarHeight = height - Self.headroomPoints * pixelsPerPoint
        return Layout(
            barWidth: barWidth,
            maxBarHeight: maxBarHeight,
            cornerRadius: min(Self.maxCornerRadiusPoints * pixelsPerPoint, barWidth / 2),
            height: height,
            peakHeight: Self.peakHeightPoints * pixelsPerPoint,
            peakOffset: Self.peakOffsetPoints * pixelsPerPoint,
            barSpacing: barSpacing
        )
    }
}
