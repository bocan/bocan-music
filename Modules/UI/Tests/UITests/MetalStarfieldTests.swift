import AudioEngine
import Foundation
import Metal
import simd
import Testing
@testable import UI

// MARK: - MetalStarfieldTests

/// Guards the Metal starfield's CPU side: the instance mapping reproduces the
/// Canvas circle/streak/opacity math at a fixed seed, the colour-resolution
/// budget holds, reduce motion freezes positions, the field is deterministic
/// under a fixed seed, and the instance struct has the documented 48-byte
/// stride. The SDF rendering itself is covered by the snapshot suite.
@Suite("MetalStarfield")
@MainActor
struct MetalStarfieldTests {
    private static let size = CGSize(width: 480, height: 480)
    private static let seed: UInt64 = 0xBADC_0FFE_E0DD_F00D
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    /// A mid-track spectrum with bass energy, so the glow instance is present.
    private static func midAnalysis(frameIndex: UInt64 = 1, onset: Bool = false) -> Analysis {
        var bands = [Float](repeating: 0, count: Starfield.bandCount)
        for index in bands.indices {
            let fraction = Float(index) / Float(bands.count)
            bands[index] = (sin(fraction * .pi * 2) * 0.5 + 0.5) * 0.8
        }
        return Analysis(
            bands: bands,
            rms: 0.5,
            peak: 0.9,
            centroid: 0.6,
            onset: onset,
            bassEnergy: 0.5,
            trebleEnergy: 0.3,
            frameIndex: frameIndex
        )
    }

    // MARK: - Stride

    @Test("StarInstance has the documented 48-byte stride")
    func instanceStride() {
        #expect(MemoryLayout<StarInstance>.stride == 48)
    }

    // MARK: - Constant pool size

    @Test("Steady-state circle frame yields 500 star instances plus one core glow")
    func constantPoolSize() {
        guard let viz = self.makeRenderer() else { return }
        let count = viz.buildInstances(analysis: Self.midAnalysis(), time: 1, drawableSize: Self.size)
        #expect(count == MetalStarfield.starCount + 1) // 500 stars + glow
        #expect(viz.instances.count == count)
    }

    // MARK: - Circle vs streak selection

    @Test("Below the streak threshold every star instance is a circle (endA == endB)")
    func circlesWhenNotStreaking() {
        guard let viz = self.makeRenderer() else { return }
        // No onset: warp boost stays at 0, well under the 0.5 streak threshold.
        viz.core.advance(analysis: Self.midAnalysis(frameIndex: 1), time: 1.0 / 60.0)
        _ = viz.buildInstances(analysis: Self.midAnalysis(frameIndex: 1), time: 1.0 / 60.0, drawableSize: Self.size)
        #expect(viz.core.warpBoost < Starfield.streakThreshold)
        // Stars follow the single glow instance, so skip index 0.
        for instance in viz.instances.dropFirst() where instance.shape == 0 {
            #expect(instance.endA == instance.endB, "circle stars collapse the capsule to a point")
        }
    }

    @Test("Above the streak threshold stars become streaks (endA != endB)")
    func streaksWhenWarping() {
        guard let viz = self.makeRenderer() else { return }
        // Spread the field out first so previous and current positions differ.
        for frame in 1 ... 30 {
            viz.core.advance(analysis: Self.midAnalysis(frameIndex: UInt64(frame)), time: Double(frame) / 60.0)
        }
        // Fire an onset to drive the warp boost to its peak, then build.
        viz.core.advance(analysis: Self.midAnalysis(frameIndex: 31, onset: true), time: 31.0 / 60.0)
        #expect(viz.core.warpBoost > Starfield.streakThreshold)
        _ = viz.buildInstances(analysis: Self.midAnalysis(frameIndex: 31, onset: true), time: 31.0 / 60.0, drawableSize: Self.size)
        var streaks = 0
        for instance in viz.instances.dropFirst() where instance.endA != instance.endB {
            streaks += 1
        }
        #expect(streaks > 0, "warping field should contain streak instances")
    }

    // MARK: - Alpha (twinkle * fadeIn) parity

    @Test("Star alpha carries twinkle * fadeIn premultiplied into the band colour")
    func alphaParity() {
        guard let viz = self.makeRenderer() else { return }
        let time = 1.0 / 60.0
        let analysis = Self.midAnalysis(frameIndex: 1)
        viz.core.advance(analysis: analysis, time: time)
        _ = viz.buildInstances(analysis: analysis, time: time, drawableSize: Self.size)

        // Reproduce the Canvas opacity for the first star directly from core state.
        let star = viz.core.stars[0]
        let bandColors = viz.core.resolveBandColors(analysis: analysis, time: time)
        let base = ColorPacking.simd(bandColors[star.bandIndex])
        let fade = min(Float(1), star.radius / Starfield.fadeInRadius)
        let twinkle = Starfield.twinkleBase + Starfield.twinkleAmplitude * sin(3 * time + Double(star.twinklePhase))
        let opacity = max(Starfield.minDrawOpacity, Double(fade) * twinkle)
        let expected = base.w * Float(opacity)

        // instances[0] is the glow; the first star is instances[1].
        #expect(abs(viz.instances[1].color.w - expected) < 1e-4)
    }

    // MARK: - Colour-resolution budget

    @Test("Colour resolution costs 32 band lookups plus one glow lookup per frame")
    func colorResolveBudget() {
        guard let viz = self.makeRenderer() else { return }
        _ = viz.buildInstances(analysis: Self.midAnalysis(), time: 1, drawableSize: Self.size)
        #expect(viz.colorResolveCount == Starfield.bandCount + 1) // 32 + glow
    }

    @Test("Colour budget holds even with no bass (glow lookup is still charged)")
    func colorResolveBudgetSilentBass() {
        guard let viz = self.makeRenderer() else { return }
        var bands = [Float](repeating: 0.2, count: Starfield.bandCount)
        bands[0] = 0
        let analysis = Analysis(bands: bands, rms: 0.1, peak: 0.2, bassEnergy: 0, frameIndex: 1)
        _ = viz.buildInstances(analysis: analysis, time: 1, drawableSize: Self.size)
        #expect(viz.colorResolveCount == Starfield.bandCount + 1)
    }

    // MARK: - Reduce motion freezes positions

    @Test("Reduce motion keeps every star position identical across 100 frames")
    func reduceMotionFreezesPositions() {
        guard let viz = self.makeRenderer(reduceMotion: true) else { return }
        _ = viz.buildInstances(analysis: Self.midAnalysis(frameIndex: 1), time: 0, drawableSize: Self.size)
        let baseline = viz.instances.dropFirst().map(\.endA)
        for frame in 2 ... 101 {
            let time = Double(frame) / 60.0
            viz.core.advance(analysis: Self.midAnalysis(frameIndex: UInt64(frame), onset: true), time: time)
            _ = viz.buildInstances(analysis: Self.midAnalysis(frameIndex: UInt64(frame)), time: time, drawableSize: Self.size)
            let positions = viz.instances.dropFirst().map(\.endA)
            #expect(positions == baseline, "frame \(frame) positions drifted under reduce motion")
        }
    }

    @Test("Reduce motion never produces streaks even on an onset")
    func reduceMotionNoStreaks() {
        guard let viz = self.makeRenderer(reduceMotion: true) else { return }
        viz.core.advance(analysis: Self.midAnalysis(frameIndex: 1, onset: true), time: 1.0 / 60.0)
        _ = viz.buildInstances(analysis: Self.midAnalysis(frameIndex: 1, onset: true), time: 1.0 / 60.0, drawableSize: Self.size)
        for instance in viz.instances.dropFirst() where instance.shape == 0 {
            #expect(instance.endA == instance.endB, "reduce motion freezes streaks into circles")
        }
    }

    // MARK: - Reduce transparency floors star alpha and uses a solid glow

    @Test("Reduce transparency floors star alpha at 0.6 and the glow is a solid disc")
    func reduceTransparencyFloor() {
        guard let viz = self.makeRenderer(reduceTransparency: true) else { return }
        let analysis = Self.midAnalysis(frameIndex: 1)
        viz.core.advance(analysis: analysis, time: 1.0 / 60.0)
        _ = viz.buildInstances(analysis: analysis, time: 1.0 / 60.0, drawableSize: Self.size)
        // Glow is a solid disc (shape 0), not the gradient (shape 1).
        #expect(viz.instances[0].shape == 0)
        // Stars (a mono palette resolves to opaque white) never dip below the
        // 0.6 floor; check the minimum across the field.
        let minAlpha = viz.instances.dropFirst().map(\.color.w).min() ?? 0
        #expect(minAlpha >= Float(Starfield.reduceTransparencyFloor) - 1e-4)
    }

    // MARK: - Determinism

    @Test("Two renderers with the same seed and scene produce identical instances")
    func determinism() {
        guard let first = self.makeRenderer(), let second = self.makeRenderer() else { return }
        for frame in 1 ... 20 {
            let analysis = Self.midAnalysis(frameIndex: UInt64(frame))
            let time = Double(frame) / 60.0
            first.core.advance(analysis: analysis, time: time)
            second.core.advance(analysis: analysis, time: time)
            _ = first.buildInstances(analysis: analysis, time: time, drawableSize: Self.size)
            _ = second.buildInstances(analysis: analysis, time: time, drawableSize: Self.size)
        }
        #expect(first.instanceCount == second.instanceCount)
        for index in 0 ..< first.instances.count {
            #expect(first.instances[index].endA == second.instances[index].endA, "instance \(index)")
            #expect(first.instances[index].color == second.instances[index].color, "instance \(index)")
        }
    }

    // MARK: - Degenerate frame guard

    @Test("A zero-size frame produces no instances")
    func zeroSizeFrame() {
        guard let viz = self.makeRenderer() else { return }
        let count = viz.buildInstances(analysis: Self.midAnalysis(), time: 1, drawableSize: .zero)
        #expect(count == 0)
    }

    // MARK: - Helpers

    private func makeRenderer(reduceMotion: Bool = false, reduceTransparency: Bool = false) -> MetalStarfield? {
        guard let device = MetalSupport.device else { return nil }
        let viz = try? MetalStarfield(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .mono, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency),
            seed: Self.seed
        )
        viz?.pixelsPerPointOverride = 1
        return viz
    }
}
