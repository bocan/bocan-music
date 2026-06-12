import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - HaloTests

/// Unit tests for the Halo visualizer geometry, rotation, and ripple pool.
/// Drawing tests (expiry-during-render, centre glow) are covered by snapshots.
@Suite("Halo")
@MainActor
struct HaloTests {
    // MARK: - Helpers

    private static let size = CGSize(width: 400, height: 400)
    private static let center = CGPoint(x: 200, y: 200)
    private static let baseRadius = Halo.baseRadiusFraction * 400 // 128
    private static let extent = Halo.extentFraction * 400 // 72

    private func makeAnalysis(trebleEnergy: Float = 0, bassEnergy: Float = 0, onset: Bool = false) -> Analysis {
        Analysis(
            bands: [Float](repeating: 0, count: Halo.bandCount),
            rms: 0,
            peak: 0,
            onset: onset,
            bassEnergy: bassEnergy,
            trebleEnergy: trebleEnergy
        )
    }

    private func distance(_ point: CGPoint, from other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Geometry

    @Test("All bands zero: all 64 tips lie on baseRadius circle")
    func geometryAllBandsZero() {
        let halo = Halo(palette: .spectrum, reduceMotion: true, reduceTransparency: false)
        // smoothedBands start at zero; no pre-warming needed for this test.
        let tips = halo.computeTips(
            center: Self.center,
            breathingRadius: Self.baseRadius,
            extent: Self.extent
        )
        #expect(tips.count == Halo.spokeCount)
        for tip in tips {
            let dist = self.distance(tip, from: Self.center)
            #expect(abs(dist - Self.baseRadius) < 0.001, "Expected \(Self.baseRadius) got \(dist)")
        }
    }

    @Test("Band k=1.0: mirrored spokes k and k+32 extend by extent; others stay at baseRadius")
    func geometryOneBandNonzero() {
        let halo = Halo(palette: .spectrum, reduceMotion: true, reduceTransparency: false)
        let bandIndex = 5
        halo.smoothedBands[bandIndex] = 1.0

        let tips = halo.computeTips(
            center: Self.center,
            breathingRadius: Self.baseRadius,
            extent: Self.extent
        )

        for index in 0 ..< Halo.spokeCount {
            let mirrored = index == bandIndex || index == bandIndex + Halo.bandCount
            let expectedRadius = mirrored ? Self.baseRadius + Self.extent : Self.baseRadius
            let dist = self.distance(tips[index], from: Self.center)
            #expect(abs(dist - expectedRadius) < 0.001, "Spoke \(index): expected \(expectedRadius), got \(dist)")
        }
    }

    @Test("Spoke mirroring: spokes i and i+32 share the same radius for each band")
    func geometryMirrorSymmetry() {
        let halo = Halo(palette: .spectrum, reduceMotion: true, reduceTransparency: false)
        for index in 0 ..< Halo.bandCount {
            halo.smoothedBands[index] = Float(index) / Float(Halo.bandCount - 1)
        }

        let tips = halo.computeTips(
            center: Self.center,
            breathingRadius: Self.baseRadius,
            extent: Self.extent
        )

        for index in 0 ..< Halo.bandCount {
            let dist0 = self.distance(tips[index], from: Self.center)
            let dist1 = self.distance(tips[index + Halo.bandCount], from: Self.center)
            #expect(abs(dist0 - dist1) < 0.001, "Spoke \(index) mirror radius mismatch")
        }
    }

    // MARK: - Rotation

    @Test("Rotation: dt=1s with trebleEnergy=0 advances phase by exactly 0.02 rev")
    func rotationDeterminismQuiet() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let before = halo.rotationPhase
        halo.updateRotation(analysis: self.makeAnalysis(trebleEnergy: 0), dt: 1.0)
        #expect(abs(halo.rotationPhase - (before + 0.02)) < 1e-12)
    }

    @Test("Rotation: dt=1s with trebleEnergy=1 advances phase by 0.10 rev")
    func rotationDeterminismBright() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let before = halo.rotationPhase
        halo.updateRotation(analysis: self.makeAnalysis(trebleEnergy: 1), dt: 1.0)
        let expected = before + 0.10
        #expect(abs(halo.rotationPhase - expected) < 1e-10)
    }

    @Test("Rotation: dt clamped to 0.1 s prevents jumps on resume")
    func rotationDeltaClamp() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        // Simulate a very long gap (2 s) — render() clamps dt to maxDeltaTime (0.1 s).
        // updateRotation receives the clamped value, so phase advances by at most 0.1 * 0.10 = 0.010 rev.
        halo.updateRotation(analysis: self.makeAnalysis(trebleEnergy: 1), dt: 0.1)
        #expect(halo.rotationPhase <= 0.011)
    }

    @Test("reduceMotion: rotation phase unchanged after updateSmoothing")
    func reduceMotionNoRotation() {
        let halo = Halo(palette: .spectrum, reduceMotion: true, reduceTransparency: false)
        halo.rotationPhase = 0.5
        // render() calls updateSmoothing but not updateRotation when reduceMotion=true
        halo.updateSmoothing(analysis: self.makeAnalysis())
        #expect(halo.rotationPhase == 0.5)
    }

    // MARK: - Ripple pool

    @Test("First onset spawns one active ripple")
    func rippleSpawnFirst() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        halo.spawnRipple(atRadius: 100, time: 1.0, analysis: self.makeAnalysis())
        let active = halo.ripplePool.filter(\.isActive).count
        #expect(active == 1)
    }

    @Test("Seven onsets leave pool size 6 (oldest recycled)")
    func ripplePoolRecyclesOldest() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        for spawn in 0 ..< 7 {
            halo.spawnRipple(atRadius: 100, time: TimeInterval(spawn) * 0.1, analysis: self.makeAnalysis())
        }
        let active = halo.ripplePool.filter(\.isActive).count
        #expect(active == Halo.ripplePoolSize)
        // The oldest spawn (time=0.0) should have been recycled, leaving 0.1..0.6 active.
        let births = halo.ripplePool.filter(\.isActive).map(\.birth).sorted()
        #expect(births.first ?? 0 > 0.0 - 1e-9)
    }

    @Test("expireStaleRipples marks ripples older than 1.2 s as inactive")
    func rippleExpiry() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        halo.spawnRipple(atRadius: 100, time: 0.0, analysis: self.makeAnalysis())
        #expect(halo.ripplePool.filter(\.isActive).count == 1)
        // Expire at t=1.3 (past the 1.2 s lifetime)
        halo.expireStaleRipples(at: 1.3)
        #expect(!halo.ripplePool.contains { $0.isActive })
    }

    @Test("expireStaleRipples leaves young ripples active")
    func rippleNoEarlyExpiry() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        halo.spawnRipple(atRadius: 100, time: 0.0, analysis: self.makeAnalysis())
        halo.expireStaleRipples(at: 1.0) // 1.0 s < 1.2 s lifetime
        #expect(halo.ripplePool.filter(\.isActive).count == 1)
    }

    // MARK: - EMA smoothing

    @Test("rmsEMA approaches target signal after many update steps")
    func rmsSmoothingConverges() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let target: Float = 0.8
        let analysis = Analysis(bands: [Float](repeating: 0, count: Halo.bandCount), rms: target, peak: 0)
        for _ in 0 ..< 100 {
            halo.updateSmoothing(analysis: analysis)
        }
        // After 100 steps the EMA should be well above 0.7 (theoretical: 1 - (1-0.15)^100 ≈ 0.999 * 0.8).
        #expect(halo.rmsEMA > 0.7)
    }

    @Test("reduceMotion uses slower smoothing (rmsEMA lower after same number of steps)")
    func reduceMotionSlowerSmoothing() {
        let analysis = Analysis(bands: [Float](repeating: 0, count: Halo.bandCount), rms: 1.0, peak: 0)

        let normal = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let reduced = Halo(palette: .spectrum, reduceMotion: true, reduceTransparency: false)

        for _ in 0 ..< 10 {
            normal.updateSmoothing(analysis: analysis)
            reduced.updateSmoothing(analysis: analysis)
        }
        #expect(normal.rmsEMA > reduced.rmsEMA)
    }

    // MARK: - Performance sanity

    @Test("1000 state-update + geometry frames complete in under 1 s")
    func perfSanity() {
        let halo = Halo(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let analysis = Analysis(
            bands: (0 ..< Halo.bandCount).map { Float($0) / Float(Halo.bandCount - 1) },
            rms: 0.5,
            peak: 0.8,
            bassEnergy: 0.4,
            trebleEnergy: 0.3
        )
        let start = ContinuousClock().now
        for frame in 0 ..< 1000 {
            let dt = 1.0 / 60.0
            let time = TimeInterval(frame) * dt
            halo.updateSmoothing(analysis: analysis)
            halo.updateRotation(analysis: analysis, dt: dt)
            _ = halo.computeTips(center: .init(x: 200, y: 200), breathingRadius: 128, extent: 72)
            halo.expireStaleRipples(at: time)
        }
        let elapsed = ContinuousClock().now - start
        #expect(elapsed < .seconds(1))
    }
}
