import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - StarfieldTests

/// Unit tests for the Starfield simulation: motion scaling, respawn, the warp
/// envelope, reduce-motion freezing, and the per-band colour cache. Drawing
/// (streaks, twinkle, glow) is covered by the snapshot suite.
@Suite("Starfield")
@MainActor
struct StarfieldTests {
    // MARK: - Helpers

    private func makeAnalysis(
        bands: [Float]? = nil,
        rms: Float = 0,
        bassEnergy: Float = 0,
        onset: Bool = false,
        frameIndex: UInt64 = 1
    ) -> Analysis {
        let resolved = bands ?? [Float](repeating: 0, count: Starfield.bandCount)
        return Analysis(
            bands: resolved,
            rms: rms,
            peak: 0,
            onset: onset,
            bassEnergy: bassEnergy,
            frameIndex: frameIndex
        )
    }

    // MARK: - Determinism

    @Test("Same seed and scripted input render identical star state")
    func determinism() {
        let one = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 42)
        let two = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 42)

        var bands = [Float](repeating: 0, count: Starfield.bandCount)
        bands[3] = 0.6
        bands[12] = 0.9
        for frame in 1 ... 120 {
            let analysis = self.makeAnalysis(bands: bands, rms: 0.4, frameIndex: UInt64(frame))
            let time = Double(frame) / 60.0
            one.advance(analysis: analysis, time: time)
            two.advance(analysis: analysis, time: time)
        }

        #expect(one.stars.count == two.stars.count)
        for index in one.stars.indices {
            #expect(one.stars[index].radius == two.stars[index].radius)
            #expect(one.stars[index].angle == two.stars[index].angle)
            #expect(one.currentNorm[index] == two.currentNorm[index])
        }
    }

    // MARK: - Motion scaling

    @Test("All bands and rms zero: radial speed equals the base")
    func baseSpeedWhenSilent() {
        let starfield = Starfield(palette: .mono, reduceMotion: false, reduceTransparency: false, seed: 7)
        // Pin a known star at a known radius on a silent band.
        starfield.stars[0] = Starfield.Star(angle: 0, radius: 0.4, size: 1.5, bandIndex: 0, twinklePhase: 0)
        starfield.currentNorm[0] = SIMD2(0.4, 0)
        starfield.prevNorm[0] = SIMD2(0.4, 0)

        // Seed lastTime so the first advance produces a real dt.
        starfield.advance(analysis: self.makeAnalysis(frameIndex: 1), time: 0.0)
        let before = starfield.stars[0].radius
        let dt: Float = 0.05
        starfield.advance(analysis: self.makeAnalysis(frameIndex: 2), time: Double(dt))
        let after = starfield.stars[0].radius

        // radius += dt * baseSpeed * (0.3 + radius)
        let expectedDelta = dt * Starfield.baseSpeed * (0.3 + before)
        #expect(abs((after - before) - expectedDelta) < 1e-5, "got \(after - before), expected \(expectedDelta)")
    }

    @Test("A loud band drives its stars faster than a quiet band")
    func bandEnergyScalesSpeed() {
        let starfield = Starfield(palette: .mono, reduceMotion: false, reduceTransparency: false, seed: 7)
        starfield.stars[0] = Starfield.Star(angle: 0, radius: 0.4, size: 1.5, bandIndex: 5, twinklePhase: 0)
        starfield.stars[1] = Starfield.Star(angle: 0, radius: 0.4, size: 1.5, bandIndex: 20, twinklePhase: 0)

        var bands = [Float](repeating: 0, count: Starfield.bandCount)
        bands[5] = 1.0
        starfield.advance(analysis: self.makeAnalysis(bands: bands, frameIndex: 1), time: 0.0)
        let loudBefore = starfield.stars[0].radius
        let quietBefore = starfield.stars[1].radius
        starfield.advance(analysis: self.makeAnalysis(bands: bands, frameIndex: 2), time: 0.05)

        let loudDelta = starfield.stars[0].radius - loudBefore
        let quietDelta = starfield.stars[1].radius - quietBefore
        #expect(loudDelta > quietDelta, "band 5 (\(loudDelta)) should outpace band 20 (\(quietDelta))")
    }

    // MARK: - Respawn

    @Test("After many frames no star exceeds maxRadius and the pool stays full")
    func respawnKeepsPoolBounded() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 99)
        let bands = [Float](repeating: 1.0, count: Starfield.bandCount)
        for frame in 1 ... 600 {
            let analysis = self.makeAnalysis(bands: bands, rms: 1.0, frameIndex: UInt64(frame))
            starfield.advance(analysis: analysis, time: Double(frame) / 60.0)
        }
        #expect(starfield.stars.count == Starfield.starCount)
        for star in starfield.stars {
            #expect(star.radius <= Starfield.maxRadius, "radius \(star.radius) exceeds max")
        }
    }

    @Test("A recycled star does not streak across the screen")
    func respawnResetsPreviousPosition() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 1)
        // Force star 0 to the edge so the next advance respawns it.
        starfield.stars[0] = Starfield.Star(angle: 0, radius: 1.09, size: 1.5, bandIndex: 0, twinklePhase: 0)
        starfield.currentNorm[0] = SIMD2(1.09, 0)
        starfield.prevNorm[0] = SIMD2(1.09, 0)

        let bands = [Float](repeating: 1.0, count: Starfield.bandCount)
        starfield.advance(analysis: self.makeAnalysis(bands: bands, frameIndex: 1), time: 0.0)
        starfield.advance(analysis: self.makeAnalysis(bands: bands, rms: 1.0, frameIndex: 2), time: 0.1)

        // After respawn, prev and current must coincide (zero-length streak).
        #expect(starfield.stars[0].radius <= Starfield.respawnRadius + 0.05)
        #expect(starfield.prevNorm[0] == starfield.currentNorm[0])
    }

    // MARK: - Warp envelope

    @Test("Onset sets warp boost to the peak")
    func onsetArmsWarp() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 3)
        starfield.advance(analysis: self.makeAnalysis(onset: true, frameIndex: 1), time: 0.0)
        #expect(abs(starfield.warpBoost - Starfield.warpPeak) < 1e-4)
    }

    @Test("Warp boost decays to peak/e after one time constant")
    func warpDecaysExponentially() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 3)
        // Onset on the first frame (dt = 0, so boost is exactly the peak).
        starfield.advance(analysis: self.makeAnalysis(onset: true, frameIndex: 1), time: 0.0)
        // Step forward by exactly one tau (0.4 s) in 0.05 s increments.
        var frame: UInt64 = 2
        var time = 0.05
        while time <= Starfield.warpDecayTau + 1e-9 {
            starfield.advance(analysis: self.makeAnalysis(frameIndex: frame), time: time)
            frame += 1
            time += 0.05
        }
        let expected = Starfield.warpPeak / Float(M_E)
        #expect(abs(starfield.warpBoost - expected) < 0.05 * expected, "boost \(starfield.warpBoost) vs \(expected)")
    }

    @Test("Two onsets in quick succession re-trigger to the peak, not above")
    func warpDoesNotStack() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 3)
        starfield.advance(analysis: self.makeAnalysis(onset: true, frameIndex: 1), time: 0.0)
        starfield.advance(analysis: self.makeAnalysis(onset: true, frameIndex: 2), time: 0.1)
        #expect(starfield.warpBoost <= Starfield.warpPeak + 1e-4)
        #expect(starfield.warpBoost >= Starfield.warpPeak - 1e-4)
    }

    @Test("The same onset frame is consumed only once")
    func onsetEdgeDetectedByFrameIndex() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: false, reduceTransparency: false, seed: 3)
        let onsetFrame = self.makeAnalysis(onset: true, frameIndex: 7)
        starfield.advance(analysis: onsetFrame, time: 0.0)
        // Re-render the identical frame after a decay gap; it must not re-arm.
        starfield.advance(analysis: onsetFrame, time: 0.2)
        #expect(starfield.warpBoost < Starfield.warpPeak)
    }

    // MARK: - Reduce motion

    @Test("Reduce motion freezes all star positions")
    func reduceMotionFreezesPositions() {
        let starfield = Starfield(palette: .spectrum, reduceMotion: true, reduceTransparency: false, seed: 5)
        let initial = starfield.stars.map(\.radius)
        let bands = [Float](repeating: 1.0, count: Starfield.bandCount)
        for frame in 1 ... 100 {
            let analysis = self.makeAnalysis(bands: bands, rms: 1.0, onset: true, frameIndex: UInt64(frame))
            starfield.advance(analysis: analysis, time: Double(frame) / 60.0)
        }
        for index in starfield.stars.indices {
            #expect(starfield.stars[index].radius == initial[index])
        }
        // No warp arming under reduce motion either.
        #expect(starfield.warpBoost == 0)
    }

    // MARK: - Colour cache

    @Test("Colour is resolved once per band plus one constant glow lookup")
    func colourCacheBudget() {
        let starfield = Starfield(palette: .drift, reduceMotion: false, reduceTransparency: false, seed: 8)
        let analysis = self.makeAnalysis(bassEnergy: 0.5, frameIndex: 1)

        let colors = starfield.resolveBandColors(analysis: analysis, time: 1.0)
        #expect(colors.count == Starfield.bandCount)
        #expect(starfield.colorResolveCount == Starfield.bandCount)

        _ = starfield.glowColor(analysis: analysis, time: 1.0)
        #expect(starfield.colorResolveCount == Starfield.bandCount + 1)
    }

    // MARK: - Allocation smoke test

    @Test("10k frames advance without crashing and keep the pool intact")
    func longRunStable() {
        let starfield = Starfield(palette: .thermal, reduceMotion: false, reduceTransparency: false, seed: 11)
        let bands = [Float](repeating: 0.5, count: Starfield.bandCount)
        for frame in 1 ... 10000 {
            let onset = frame % 43 == 0
            let analysis = self.makeAnalysis(bands: bands, rms: 0.5, bassEnergy: 0.4, onset: onset, frameIndex: UInt64(frame))
            starfield.advance(analysis: analysis, time: Double(frame) / 60.0)
        }
        #expect(starfield.stars.count == Starfield.starCount)
    }
}
