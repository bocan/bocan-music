import AppKit
import AudioEngine
import MetalKit
import simd

// MARK: - StarInstance

/// CPU mirror of the MSL `StarInstance`. Stride is 48 (the trailing `SIMD4`
/// alignment rounds the fields up), asserted in the tests. One instance is
/// either a star (a capsule: a circle when `endA == endB`, a streak otherwise)
/// or the core glow (`shape == 1` radial disc), so a single instanced draw and
/// a single SDF cover every shape.
struct StarInstance {
    /// Pixel position this frame (capsule endpoint A, or the glow centre).
    var endA: SIMD2<Float>
    /// Pixel position last frame (== `endA` for a circle).
    var endB: SIMD2<Float>
    /// sRGB colour with the twinkle/fade opacity already pre-applied into alpha.
    var color: SIMD4<Float>
    /// Pixels: circle radius, half streak width, or glow radius.
    var radius: Float
    /// 0 = star capsule, 1 = core-glow radial disc.
    var shape: Float
    /// Unused; keeps the documented 48-byte stride explicit (`radius` and
    /// `shape` precede it so the two scalars pack into the 16-byte tail without
    /// forcing a second alignment gap).
    var pad: SIMD2<Float>
}

// MARK: - MetalStarfield

/// Metal port of the Canvas ``Starfield``, built by composition: it holds a
/// `Starfield` instance, drives its simulation via `advance(analysis:time:)`
/// once per frame, then reads the star pool, normalised positions, warp boost,
/// and resolved band colours to build GPU instances. The Canvas renderer stays
/// the visual-parity reference and the single source of the motion, twinkle,
/// fade-in, and accessibility math.
///
/// Stars and the core glow render as instanced capsule/disc SDFs in one draw
/// call. A circle is a capsule whose endpoints coincide, so circles and streaks
/// share one pipeline with no per-instance branch on a mode flag.
@MainActor
final class MetalStarfield: MetalVisualizer {
    // MARK: - Constants (mirrored from the Canvas renderer)

    static let starCount = Starfield.starCount
    static let bandCount = Starfield.bandCount

    // MARK: - Configuration

    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    /// Test seam mirroring `MetalSpectrumBars.pixelsPerPointOverride`: snapshot
    /// tests pin it to 1 so point-sized star widths map straight to pixels.
    var pixelsPerPointOverride: CGFloat?
    private var pixelsPerPoint: CGFloat {
        self.pixelsPerPointOverride ?? (NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - GPU state

    private let pipeline: MTLRenderPipelineState
    private let frameRing: FrameRing

    // MARK: - CPU state (internal for testing)

    /// The composed Canvas simulation. All motion/respawn/twinkle/warp rules live
    /// here; `MetalStarfield` only reads its state and maps it to instances.
    private(set) var core: Starfield
    private(set) var instances = [StarInstance]()
    private(set) var instanceCount = 0
    /// `PaletteResolver.color` calls made building the most recent frame. Guards
    /// the per-band caching contract (32 band colours + the single glow colour).
    private(set) var colorResolveCount = 0
    private var currentBuffer: MTLBuffer?
    private var drawableSize: SIMD2<Float> = .zero

    // MARK: - Init

    convenience init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {
        // Production entry point: a random seed (nil) so the live field differs
        // run to run, exactly as the Canvas renderer does.
        try self.init(device: device, pixelFormat: pixelFormat, config: config, seed: nil)
    }

    /// Deterministic-seed initializer for snapshot and golden tests. Mirrors the
    /// Canvas `Starfield(seed:)` seam so the Metal output is comparable to the
    /// Canvas fixture under the same seed and scripted scene.
    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig, seed: UInt64?) throws {
        self.reduceMotion = config.reduceMotion
        self.reduceTransparency = config.reduceTransparency
        self.core = Starfield(
            palette: config.palette,
            reduceMotion: config.reduceMotion,
            reduceTransparency: config.reduceTransparency,
            seed: seed
        )
        // Stars + the single core-glow instance.
        self.instances.reserveCapacity(Self.starCount + 1)

        let library = try MetalShaderLibrary.library(named: "Starfield", device: device)
        guard let vertexFunction = library.makeFunction(name: "starfield_vertex") else {
            throw MetalRendererError.missingFunction(name: "starfield_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "starfield_fragment") else {
            throw MetalRendererError.missingFunction(name: "starfield_fragment")
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

        let bytesPerSlot = (Self.starCount + 1) * MemoryLayout<StarInstance>.stride
        guard let ring = FrameRing(device: device, bytesPerSlot: bytesPerSlot) else {
            throw MetalRendererError.resourceAllocationFailed(reason: "starfield frame ring")
        }
        self.frameRing = ring
    }

    // MARK: - MetalVisualizer

    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {
        self.drawableSize = SIMD2(Float(drawableSize.width), Float(drawableSize.height))

        // One simulation step on the composed Canvas core (warp envelope, radial
        // motion, respawn; frozen under reduce motion).
        self.core.advance(analysis: analysis, time: time)

        self.instanceCount = self.buildInstances(analysis: analysis, time: time, drawableSize: drawableSize)

        let buffer = self.frameRing.acquire()
        self.currentBuffer = buffer
        guard self.instanceCount > 0 else { return }
        self.instances.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let byteCount = self.instanceCount * MemoryLayout<StarInstance>.stride
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
        // Single instanced draw: the core glow is emitted first so the stars
        // blend over it (primitive order is blend order within one draw call).
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: self.instanceCount
        )
    }

    func didEncode(commandBuffer: MTLCommandBuffer) {
        self.frameRing.release(when: commandBuffer)
    }

    // MARK: - Instance building (internal for testing)

    /// Builds the core-glow instance (when bass is present) followed by the 500
    /// star instances into `self.instances` and returns the count. Reproduces the
    /// Canvas `drawStars`/`drawCoreGlow` opacity, circle-vs-streak, and dot-radius
    /// math against the composed core's state. Resolves 32 band colours once.
    func buildInstances(analysis: Analysis, time: TimeInterval, drawableSize: CGSize) -> Int {
        self.instances.removeAll(keepingCapacity: true)
        self.colorResolveCount = 0

        guard drawableSize.width > 0, drawableSize.height > 0 else { return 0 }

        let bandColors = self.core.resolveBandColors(analysis: analysis, time: time)
        self.colorResolveCount += bandColors.count
        let packed = bandColors.map { ColorPacking.simd($0) }

        let minDim = Float(min(drawableSize.width, drawableSize.height))
        let scale = minDim / 2
        let center = SIMD2<Float>(Float(drawableSize.width) / 2, Float(drawableSize.height) / 2)
        let perPoint = Float(self.pixelsPerPoint)

        // Core glow first so stars blend on top, matching the Canvas draw order.
        self.appendGlow(analysis: analysis, time: time, center: center, minDim: minDim)

        let bandCount = analysis.bands.count
        let streaking = !self.reduceMotion && self.core.warpBoost > Starfield.streakThreshold
        let amplitude = self.reduceMotion ? Starfield.twinkleReducedAmplitude : Starfield.twinkleAmplitude
        let floorOpacity = self.reduceTransparency ? Starfield.reduceTransparencyFloor : Starfield.minDrawOpacity

        for index in self.core.stars.indices {
            let star = self.core.stars[index]
            let current = self.core.currentNorm[index]
            let point = center + current * scale

            // Opacity math, identical to the Canvas: fade-in ramp times twinkle,
            // floored. Reduce transparency drops the radial fade.
            let fade = self.reduceTransparency ? 1 : min(1, star.radius / Starfield.fadeInRadius)
            let twinkle = Starfield.twinkleBase + amplitude * sin(3 * time + Double(star.twinklePhase))
            var opacity = Double(fade) * twinkle
            opacity = max(floorOpacity, opacity)

            var color = packed[star.bandIndex]
            color.w *= Float(opacity)

            if streaking {
                // Streak: a capsule from the previous position to the current one,
                // half-width = size / 2 (the Canvas strokes a line of width size).
                let previous = self.core.prevNorm[index]
                let from = center + previous * scale
                self.instances.append(StarInstance(
                    endA: point,
                    endB: from,
                    color: color,
                    radius: star.size * perPoint / 2,
                    shape: 0,
                    pad: .zero
                ))
            } else {
                // Circle: a degenerate capsule (endA == endB). Radius follows the
                // Canvas dot formula, band-energy-modulated.
                let bandEnergy = star.bandIndex < bandCount ? analysis.bands[star.bandIndex] : 0
                let dotRadius = star.size * (0.6 + 0.6 * bandEnergy) * perPoint
                self.instances.append(StarInstance(
                    endA: point,
                    endB: point,
                    color: color,
                    radius: dotRadius,
                    shape: 0,
                    pad: .zero
                ))
            }
        }
        return self.instances.count
    }

    // MARK: - Core glow (private)

    /// Emits the central glow instance, mirroring the Canvas `drawCoreGlow`: a
    /// radial-gradient disc normally, a solid dim disc under reduce transparency,
    /// nothing when there is no bass. The single resolver budget is consumed
    /// whether or not bass is present, matching the Canvas frame count.
    private func appendGlow(analysis: Analysis, time: TimeInterval, center: SIMD2<Float>, minDim: Float) {
        guard analysis.bassEnergy > 0 else {
            self.colorResolveCount += 1
            return
        }
        let glow = ColorPacking.simd(self.core.glowColor(analysis: analysis, time: time))
        self.colorResolveCount += 1
        let radius = Float(Starfield.glowRadiusFraction) * minDim

        if self.reduceTransparency {
            // Solid dim disc: a hard-edged capsule circle (shape 0) at the
            // clamped dim alpha.
            var color = glow
            color.w = min(0.4, Float(analysis.bassEnergy))
            self.instances.append(StarInstance(
                endA: center, endB: center, color: color, radius: radius, shape: 0, pad: .zero
            ))
        } else {
            // Radial-gradient disc (shape 1): alpha fades from bassEnergy at the
            // centre to clear at the edge.
            var color = glow
            color.w = Float(analysis.bassEnergy)
            self.instances.append(StarInstance(
                endA: center, endB: center, color: color, radius: radius, shape: 1, pad: .zero
            ))
        }
    }
}
