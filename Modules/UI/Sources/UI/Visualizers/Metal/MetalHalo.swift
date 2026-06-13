import AppKit
import AudioEngine
import MetalKit
import Observability
import simd

// MARK: - HaloVertex

/// CPU mirror of the MSL `HaloVertex`. A `SIMD2<Float>` position followed by a
/// `SIMD4<Float>` colour; the `SIMD4` forces 16-byte alignment, giving a 32-byte
/// stride (asserted in the tests). Shared by the membrane fan and the rim ribbon.
struct HaloVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

// MARK: - HaloShapeInstance

/// CPU mirror of the MSL `HaloShapeInstance`. One ripple ring or the centre glow;
/// stride is 48 bytes (the `SIMD4` alignment pads the scalar tail), asserted in
/// the tests.
struct HaloShapeInstance {
    var center: SIMD2<Float>
    var radius: Float
    var halfWidth: Float
    var color: SIMD4<Float>
    var kind: Float
}

// MARK: - MetalHalo

/// Metal port of the Canvas ``Halo``. The audio-driven state machine (EMA
/// smoothing, rotation, breathing, tip computation, ripple pool) is **composed,
/// not duplicated**: this renderer holds a ``Halo`` instance, drives it through
/// its internal methods, and reads back its state. Only the geometry expansion
/// (Catmull-Rom tips to a sampled loop, fan, rim ribbon, ripple/glow instances)
/// and the GPU encoding live here; the Canvas renderer stays the parity reference.
@MainActor
final class MetalHalo: MetalVisualizer {
    // MARK: - Constants

    /// 64 spoke segments (the mirrored band count), each Bezier-sampled into
    /// 8 steps, yielding the 512-point closed loop the fan and ribbon consume.
    static let segmentCount = Halo.spokeCount
    /// Bezier steps per segment.
    static let stepsPerSegment = 8
    /// Closed-loop point count: one point per step over every segment.
    static let loopPointCount = segmentCount * stepsPerSegment
    /// Fan vertex count: the centre plus the closed loop plus the repeated first
    /// loop point that closes the wrap.
    static let fanVertexCount = loopPointCount + 2
    /// Closed-ribbon vertex count: two strip vertices per loop point plus the
    /// repeated first pair (``PolylineRibbon/strip(points:width:closed:)``).
    static let ribbonVertexCount = loopPointCount * 2 + 2
    private static let rimWidthPoints: CGFloat = 2
    private static let rippleMaxRadiusFraction: CGFloat = 1.2
    private static let rippleSpawnWidthPoints: Float = 3
    private static let rippleEndWidthPoints: Float = 1
    private static let rippleSpawnOpacity: Float = 0.5
    private static let fillOpacity: Float = 0.25

    /// Glow shape kinds, mirrored in `Halo.metal`.
    private static let kindRing: Float = 0
    private static let kindGradientGlow: Float = 1
    private static let kindFlatGlow: Float = 2

    // MARK: - Composed state machine

    /// The tested Canvas state machine. ``MetalHalo`` steps it once per frame and
    /// reads its `rmsEMA` / `smoothedBands` / `rotationPhase` / `ripplePool`.
    let core: Halo

    // MARK: - Configuration

    /// Palette and flags are held here too because ``Halo``'s palette is private;
    /// the colour lookups (fill, glow, the 32-band array) happen on this side.
    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    /// Backing scale used to convert point widths to pixels. A test seam lets
    /// snapshots render at scale 1 so references are resolution-independent.
    var pixelsPerPointOverride: CGFloat?
    private var pixelsPerPoint: CGFloat {
        self.pixelsPerPointOverride ?? (NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - GPU state

    private let geometryPipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let geometryRing: FrameRing
    private let shapeRing: FrameRing
    /// Static fan index buffer: `(centre, loop[i], loop[i+1])` triples. Built once
    /// so the membrane draws as a triangle fan through the shared straight-vid
    /// geometry shader (Metal has no `.triangleFan` primitive on Apple Silicon).
    private let fanIndexBuffer: MTLBuffer
    private let fanIndexCount: Int

    // MARK: - CPU state (internal for testing)

    /// dt clamp lives on this side so the composed `core` is stepped exactly once
    /// per frame (it does not call `Halo.render`, which owns its own `lastTime`).
    private(set) var lastTime: TimeInterval = 0
    private(set) var fanVertices = [HaloVertex]()
    private(set) var ribbonVertices = [HaloVertex]()
    private(set) var shapeInstances = [HaloShapeInstance]()
    private var bandColors = [SIMD4<Float>](repeating: .zero, count: Halo.bandCount)
    private var loopPoints = [SIMD2<Float>](repeating: .zero, count: loopPointCount)
    private var drawableSize: SIMD2<Float> = .zero
    private var geometryBuffer: MTLBuffer?
    private var shapeBuffer: MTLBuffer?
    /// Byte offset of the ribbon vertices within the shared geometry slot (the
    /// fan occupies `[0, ribbonByteOffset)`).
    private static let ribbonByteOffset = fanVertexCount * MemoryLayout<HaloVertex>.stride

    private let log = AppLogger.make(.ui)

    // MARK: - Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        self.palette = config.palette
        self.reduceMotion = config.reduceMotion
        self.reduceTransparency = config.reduceTransparency
        self.core = Halo(
            palette: config.palette,
            reduceMotion: config.reduceMotion,
            reduceTransparency: config.reduceTransparency
        )
        self.fanVertices.reserveCapacity(Self.fanVertexCount)
        self.ribbonVertices.reserveCapacity(Self.ribbonVertexCount)
        self.shapeInstances.reserveCapacity(Halo.ripplePoolSize + 1)

        let library = try MetalShaderLibrary.library(named: "Halo", device: device)
        self.geometryPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: pixelFormat,
            vertex: "halo_geometry_vertex",
            fragment: "halo_geometry_fragment"
        )
        self.shapePipeline = try Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: pixelFormat,
            vertex: "halo_shape_vertex",
            fragment: "halo_shape_fragment"
        )

        // Fan and ribbon share one slot: fan at offset 0, ribbon after it.
        let geometryBytes = (Self.fanVertexCount + Self.ribbonVertexCount) * MemoryLayout<HaloVertex>.stride
        guard let geometryRing = FrameRing(device: device, bytesPerSlot: geometryBytes) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "halo geometry frame ring")
        }
        self.geometryRing = geometryRing
        let shapeBytes = (Halo.ripplePoolSize + 1) * MemoryLayout<HaloShapeInstance>.stride
        guard let shapeRing = FrameRing(device: device, bytesPerSlot: shapeBytes) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "halo shape frame ring")
        }
        self.shapeRing = shapeRing

        let indices = Self.fanIndices()
        self.fanIndexCount = indices.count
        guard let indexBuffer = device.makeBuffer(
            bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: .storageModeShared
        ) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "halo fan index buffer")
        }
        self.fanIndexBuffer = indexBuffer

        self.log.debug("visualizer.metal.halo.init", [
            "fanVertices": Self.fanVertexCount,
            "ribbonVertices": Self.ribbonVertexCount,
        ])
    }

    /// Builds one of the two render pipelines with standard source-over alpha
    /// blending (every layer the Canvas renderer draws is alpha-blended).
    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat,
        vertex: String,
        fragment: String
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw MetalRendererError.missingFunction(name: vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw MetalRendererError.missingFunction(name: fragment)
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
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(reason: String(reflecting: error))
        }
    }

    /// The static fan index triples `(0, i, i+1)`, drawing the membrane as a
    /// triangle fan around vertex 0 (the centre) over the closed loop. The loop's
    /// last buffer slot repeats the first loop point, so the final wrap triangle
    /// is well formed without special-casing.
    static func fanIndices() -> [UInt16] {
        var indices = [UInt16]()
        indices.reserveCapacity(Self.loopPointCount * 3)
        for index in 0 ..< Self.loopPointCount {
            indices.append(0)
            indices.append(UInt16(index + 1))
            indices.append(UInt16(index + 2))
        }
        return indices
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        // The state step and geometry live in `buildFrame`, which never touches
        // the GPU ring; the ring is acquired here once per frame so `update` and
        // `didEncode` stay balanced and the CPU build is testable device-free.
        self.buildFrame(analysis: analysis, time: time, drawableSize: drawableSize)
        self.writeBuffers()
    }

    /// Steps the composed state machine once and rebuilds all geometry into the
    /// preallocated arrays. Pure CPU and ring-free, so the tests drive it
    /// directly; callers read the `fanVertices` / `ribbonVertices` /
    /// `shapeInstances` arrays (empty on a degenerate frame).
    func buildFrame(analysis: Analysis, time: TimeInterval, drawableSize: CGSize) {
        self.drawableSize = SIMD2(Float(drawableSize.width), Float(drawableSize.height))

        // Step the composed state machine once per frame, exactly as `Halo.render`
        // does, but owning the dt clamp and `lastTime` here.
        let dt = self.lastTime == 0 ? 0 : min(time - self.lastTime, Halo.maxDeltaTime)
        self.lastTime = time
        self.core.updateSmoothing(analysis: analysis)
        if !self.reduceMotion {
            self.core.updateRotation(analysis: analysis, dt: dt)
        }

        let center = SIMD2(self.drawableSize.x / 2, self.drawableSize.y / 2)
        let minDim = min(self.drawableSize.x, self.drawableSize.y)
        // Degenerate pane during a window animation: skip rather than emit NaNs.
        guard minDim > 0 else {
            self.fanVertices.removeAll(keepingCapacity: true)
            self.ribbonVertices.removeAll(keepingCapacity: true)
            self.shapeInstances.removeAll(keepingCapacity: true)
            return
        }

        let baseRadius = Float(Halo.baseRadiusFraction) * minDim
        let extent = Float(Halo.extentFraction) * minDim
        let breathingRadius = baseRadius * (1 + Float(Halo.breathingDepth) * (self.core.rmsEMA * 2 - 1))

        if !self.reduceMotion, analysis.onset {
            self.core.spawnRipple(
                atRadius: CGFloat(breathingRadius + extent), time: time, analysis: analysis
            )
        }
        // Expire before building instances so the pool matches the Canvas
        // timeline (the Canvas version expires lazily inside its draw loop).
        self.core.expireStaleRipples(at: time)

        self.resolveBandColors(analysis: analysis, time: time)
        self.buildLoop(centerPixel: center, breathingRadius: breathingRadius, extent: extent)
        self.buildFan(analysis: analysis, time: time)
        self.buildRibbon()
        self.buildShapes(
            center: center, minDim: minDim, breathingRadius: breathingRadius, analysis: analysis, time: time
        )
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        var size = self.drawableSize
        // Draw order matches the Canvas: fill fan, rim ribbon, shapes (ripples
        // then glow). Primitive order within a call is blend order.
        if let geometry = self.geometryBuffer, !self.fanVertices.isEmpty {
            encoder.setRenderPipelineState(self.geometryPipeline)
            encoder.setVertexBuffer(geometry, offset: 0, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: self.fanIndexCount,
                indexType: .uint16,
                indexBuffer: self.fanIndexBuffer,
                indexBufferOffset: 0
            )
        }
        if let geometry = self.geometryBuffer, !self.ribbonVertices.isEmpty {
            // Bind the ribbon region so its vertex_ids index from 0.
            encoder.setRenderPipelineState(self.geometryPipeline)
            encoder.setVertexBuffer(geometry, offset: Self.ribbonByteOffset, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: self.ribbonVertices.count)
        }
        if let shapeBuffer = self.shapeBuffer, !self.shapeInstances.isEmpty {
            encoder.setRenderPipelineState(self.shapePipeline)
            encoder.setVertexBuffer(shapeBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: self.shapeInstances.count
            )
        }
    }

    func didEncode(commandBuffer: MTLCommandBuffer) {
        self.geometryRing.release(when: commandBuffer)
        self.shapeRing.release(when: commandBuffer)
    }
}

// MARK: - Geometry, colour, and buffer upload

extension MetalHalo {
    // MARK: - Colour resolution (internal for testing)

    /// Resolves one colour per band (32 lookups), shared by both mirrored spoke
    /// copies, exactly like `Halo.resolveBandColors`. Never per vertex: 512 loop
    /// points times the drift palette's hue math would tank the frame.
    func resolveBandColors(analysis: Analysis, time: TimeInterval) {
        for band in 0 ..< Halo.bandCount {
            let position = Double(band) / Double(Halo.bandCount - 1)
            self.bandColors[band] = ColorPacking.simd(PaletteResolver.color(
                palette: self.palette,
                position: position,
                magnitude: self.core.smoothedBands[band],
                analysis: analysis,
                time: time
            ))
        }
    }

    // MARK: - Geometry (internal for testing)

    /// Samples the closed Catmull-Rom loop into `loopPoints` (pixel space). Reuses
    /// the composed `core.computeTips`, then evaluates the same cubic Bezier
    /// control points `Halo.buildCatmullRomPath` uses, at 8 steps per segment.
    func buildLoop(centerPixel: SIMD2<Float>, breathingRadius: Float, extent: Float) {
        let cgTips = self.core.computeTips(
            center: CGPoint(x: CGFloat(centerPixel.x), y: CGFloat(centerPixel.y)),
            breathingRadius: CGFloat(breathingRadius),
            extent: CGFloat(extent)
        )
        let tips = cgTips.map { SIMD2(Float($0.x), Float($0.y)) }
        let count = tips.count
        for segment in 0 ..< count {
            let prev = tips[(segment - 1 + count) % count]
            let curr = tips[segment]
            let next = tips[(segment + 1) % count]
            let afterNext = tips[(segment + 2) % count]
            let ctrl1 = curr + (next - prev) / 6
            let ctrl2 = next - (afterNext - curr) / 6
            for step in 0 ..< Self.stepsPerSegment {
                let t = Float(step) / Float(Self.stepsPerSegment)
                let point = Self.bezier(curr, ctrl1, ctrl2, next, t)
                self.loopPoints[segment * Self.stepsPerSegment + step] = point
            }
        }
    }

    /// Cubic Bezier point at parameter `t`. `t = 0` yields `p0`, `t = 1` yields
    /// `p3`; exposed static so the sampling is unit-testable.
    static func bezier(
        _ p0: SIMD2<Float>,
        _ p1: SIMD2<Float>,
        _ p2: SIMD2<Float>,
        _ p3: SIMD2<Float>,
        _ t: Float
    ) -> SIMD2<Float> {
        let inv = 1 - t
        let w0 = inv * inv * inv
        let w1 = 3 * inv * inv * t
        let w2 = 3 * inv * t * t
        let w3 = t * t * t
        return p0 * w0 + p1 * w1 + p2 * w2 + p3 * w3
    }

    /// Builds the membrane triangle-fan vertices: the centre (with the fill
    /// colour, never zero alpha) plus the closed loop plus the repeated first
    /// loop point. The fan is always valid because every loop point's radius is at
    /// least `breathingRadius > 0`, so the membrane is star-shaped about the
    /// centre (guarded by the fan-validity test).
    func buildFan(analysis: Analysis, time: TimeInterval) {
        var fill = ColorPacking.simd(PaletteResolver.color(
            palette: self.palette, position: 0.5, magnitude: self.core.rmsEMA, analysis: analysis, time: time
        ))
        fill.w *= self.reduceTransparency ? 1 : Self.fillOpacity
        let center = SIMD2(self.drawableSize.x / 2, self.drawableSize.y / 2)
        self.fanVertices.removeAll(keepingCapacity: true)
        // Centre carries the fill colour too; a zero-alpha centre would fade the
        // membrane towards the middle.
        self.fanVertices.append(HaloVertex(position: center, color: fill))
        for point in self.loopPoints {
            self.fanVertices.append(HaloVertex(position: point, color: fill))
        }
        // Repeat the first loop point so the final fan triangle closes the wrap.
        self.fanVertices.append(HaloVertex(position: self.loopPoints[0], color: fill))
    }

    /// Builds the closed rim ribbon: a 2 pt triangle-strip stroke of the loop with
    /// a per-vertex band colour. The strip emits two vertices per loop point plus
    /// a repeated first pair; the colour array repeats the first pair too so the
    /// closed seam does not flash the wrong band.
    func buildRibbon() {
        let width = Float(Self.rimWidthPoints) * Float(self.pixelsPerPoint)
        let strip = PolylineRibbon.strip(points: self.loopPoints, width: width, closed: true)
        self.ribbonVertices.removeAll(keepingCapacity: true)
        for (index, point) in strip.enumerated() {
            // Two strip vertices per loop point; the trailing repeated pair maps
            // back to loop point 0 so the seam colour matches.
            let loopIndex = (index / 2) % Self.loopPointCount
            let segment = loopIndex / Self.stepsPerSegment
            let band = segment < Halo.bandCount ? segment : segment - Halo.bandCount
            self.ribbonVertices.append(HaloVertex(position: point, color: self.bandColors[band]))
        }
    }

    /// Builds the ripple ring instances and the centre glow instance, mirroring
    /// `Halo.drawRipples` and `Halo.drawCentreGlow` presentation. Ripple pool
    /// state comes entirely from the composed `core` (already expired in `update`).
    func buildShapes(
        center: SIMD2<Float>,
        minDim: Float,
        breathingRadius: Float,
        analysis: Analysis,
        time: TimeInterval
    ) {
        self.shapeInstances.removeAll(keepingCapacity: true)
        let scale = Float(self.pixelsPerPoint)
        let maxRadius = Float(Self.rippleMaxRadiusFraction) * minDim
        for ripple in self.core.ripplePool where ripple.isActive {
            let age = Float(time - ripple.birth)
            let progress = age / Float(Halo.rippleLifetime)
            guard progress <= 1 else { continue }
            let spawnRadius = Float(ripple.spawnRadius)
            let radius = spawnRadius + progress * (maxRadius - spawnRadius)
            let lineWidth = (Self.rippleSpawnWidthPoints - (Self.rippleSpawnWidthPoints - Self.rippleEndWidthPoints) * progress) * scale
            var color = ColorPacking.simd(ripple.color)
            color.w *= Self.rippleSpawnOpacity * (1 - progress)
            self.shapeInstances.append(HaloShapeInstance(
                center: center, radius: radius, halfWidth: lineWidth / 2, color: color, kind: Self.kindRing
            ))
        }
        self.appendGlow(center: center, radius: breathingRadius, analysis: analysis, time: time)
    }

    /// Appends the centre-glow instance unless `bassEnergy == 0` (skipped exactly
    /// like the Canvas renderer). Gradient glow normally; a flat disc under reduce
    /// transparency.
    private func appendGlow(center: SIMD2<Float>, radius: Float, analysis: Analysis, time: TimeInterval) {
        guard analysis.bassEnergy > 0 else { return }
        var color = ColorPacking.simd(PaletteResolver.color(
            palette: self.palette, position: 0.5, magnitude: analysis.bassEnergy, analysis: analysis, time: time
        ))
        let kind: Float
        if self.reduceTransparency {
            kind = Self.kindFlatGlow
        } else {
            kind = Self.kindGradientGlow
            color.w *= analysis.bassEnergy
        }
        self.shapeInstances.append(HaloShapeInstance(
            center: center, radius: radius, halfWidth: 0, color: color, kind: kind
        ))
    }

    // MARK: - Buffer upload

    /// Acquires both frame-ring slots and uploads the geometry and instances;
    /// always acquires (even on an empty frame) so acquire/release stay balanced.
    private func writeBuffers() {
        let geometry = self.geometryRing.acquire()
        let shapes = self.shapeRing.acquire()
        self.geometryBuffer = geometry
        self.shapeBuffer = shapes
        Self.upload(self.fanVertices, into: geometry, offset: 0)
        Self.upload(self.ribbonVertices, into: geometry, offset: Self.ribbonByteOffset)
        Self.upload(self.shapeInstances, into: shapes, offset: 0)
    }

    /// Copies a contiguous array of trivial elements into a buffer at a byte
    /// offset, bounds-checked.
    private static func upload(_ values: [some Any], into buffer: MTLBuffer, offset: Int) {
        guard !values.isEmpty else { return }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, offset + raw.count <= buffer.length else { return }
            buffer.contents().advanced(by: offset).copyMemory(from: base, byteCount: raw.count)
        }
    }
}
