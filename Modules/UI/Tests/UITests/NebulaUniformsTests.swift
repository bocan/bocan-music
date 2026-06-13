import AudioEngine
import Foundation
import simd
import Testing
@testable import UI

// MARK: - NebulaUniformsTests

/// Guards the Nebula CPU core (``NebulaState`` + ``NebulaUniforms``): the flow
/// clock integrates from the audio, the onset envelope and its two consumers
/// behave, the wisp orbits are deterministic and bounded, band-group energies
/// drive strength and radius, the LUT matches `rampStops`, and the uniform struct
/// has the documented stride. The GPU shader is covered by the snapshot suite.
@Suite("NebulaUniforms")
@MainActor
struct NebulaUniformsTests {
    private static let size = CGSize(width: 800, height: 600)
    private static let oneFrame: TimeInterval = 1.0 / 60.0

    private static func analysis(
        bands: [Float]? = nil,
        centroid: Float = 0.5,
        onset: Bool = false,
        bassEnergy: Float = 0,
        midEnergy: Float = 0,
        frameIndex: UInt64 = 1
    ) -> Analysis {
        let resolved = bands ?? [Float](repeating: 0, count: 32)
        return Analysis(
            bands: resolved,
            rms: 0,
            peak: 0,
            centroid: centroid,
            onset: onset,
            bassEnergy: bassEnergy,
            midEnergy: midEnergy,
            trebleEnergy: 0,
            frameIndex: frameIndex
        )
    }

    /// Drives `state` through `seconds` of analysis at 60 Hz with a fresh
    /// frameIndex each step, returning the final flowTime. A priming frame at
    /// time 0 seeds `lastTime` so every one of the `seconds`-worth of frames
    /// contributes a full `dt` to the integral.
    private static func integrate(
        _ state: inout NebulaState,
        seconds: Double,
        bassEnergy: Float,
        onset: Bool = false
    ) -> Double {
        _ = state.update(
            analysis: self.analysis(onset: onset, bassEnergy: bassEnergy, frameIndex: 0),
            time: 0,
            drawableSize: self.size
        )
        let steps = Int((seconds / Self.oneFrame).rounded())
        for step in 1 ... steps {
            let time = Double(step) * Self.oneFrame
            _ = state.update(
                analysis: Self.analysis(onset: onset, bassEnergy: bassEnergy, frameIndex: UInt64(step)),
                time: time,
                drawableSize: Self.size
            )
        }
        return state.flowTime
    }

    // MARK: - Stride

    @Test("NebulaUniforms is 96 bytes (matches the MSL struct)")
    func uniformStride() {
        #expect(MemoryLayout<NebulaUniforms>.stride == 96)
        #expect(MemoryLayout<NebulaUniforms>.alignment == 16)
    }

    // MARK: - flowTime integration

    @Test("One second of silence advances flowTime by the 0.02 baseline")
    func flowTimeSilence() {
        var state = NebulaState()
        let flow = Self.integrate(&state, seconds: 1.0, bassEnergy: 0)
        #expect(abs(flow - 0.02) < 0.001, "flow \(flow)")
    }

    @Test("One second of full bass advances flowTime by 0.32 (0.02 + 0.30)")
    func flowTimeFullBass() {
        var state = NebulaState()
        let flow = Self.integrate(&state, seconds: 1.0, bassEnergy: 1.0)
        #expect(abs(flow - 0.32) < 0.005, "flow \(flow)")
    }

    @Test("flowTime never decreases across a mixed scripted sequence")
    func flowTimeMonotonic() {
        var state = NebulaState()
        var previous = state.flowTime
        let scenarios: [(Float, Bool)] = [(0, false), (1, false), (0, true), (0.5, false), (0, false)]
        var frame: UInt64 = 0
        for (bass, onset) in scenarios {
            for _ in 0 ..< 30 {
                frame += 1
                _ = state.update(
                    analysis: Self.analysis(onset: onset, bassEnergy: bass, frameIndex: frame),
                    time: Double(frame) * Self.oneFrame,
                    drawableSize: Self.size
                )
                #expect(state.flowTime >= previous, "flowTime decreased at frame \(frame)")
                previous = state.flowTime
            }
        }
    }

    // MARK: - Onset envelope (tau 0.3) and consumers

    @Test("An onset boosts exposure, by no more than 20%")
    func onsetExposureBoost() {
        var state = NebulaState()
        // Prime lastTime so the onset frame has a real dt.
        _ = state.update(analysis: Self.analysis(frameIndex: 1), time: 0, drawableSize: Self.size)
        let onsetUniforms = state.update(
            analysis: Self.analysis(onset: true, frameIndex: 2),
            time: Self.oneFrame,
            drawableSize: Self.size
        )
        // Envelope is 1.0 on the onset frame -> exposure at the 20% ceiling.
        #expect(abs(onsetUniforms.exposure - 1.2) < 1e-4, "exposure \(onsetUniforms.exposure)")
        #expect(onsetUniforms.exposure <= 1.2 + 1e-4)
        #expect(onsetUniforms.onsetPulse <= 1.0 + 1e-6)
    }

    @Test("The onset envelope decays to ~1/e after one tau (0.3 s)")
    func onsetEnvelopeTau() {
        var state = NebulaState()
        _ = state.update(analysis: Self.analysis(frameIndex: 1), time: 0, drawableSize: Self.size)
        // Onset frame: pulse re-arms to 1.0. Seed `last` from it (not a hand-built
        // placeholder) so the loop below overwrites a real value.
        var last = state.update(
            analysis: Self.analysis(onset: true, frameIndex: 2),
            time: Self.oneFrame,
            drawableSize: Self.size
        )
        var frame: UInt64 = 2
        var time = Self.oneFrame
        // Advance one tau with no further onset.
        while time < Self.oneFrame + NebulaState.onsetTau {
            frame += 1
            time += Self.oneFrame
            last = state.update(analysis: Self.analysis(frameIndex: frame), time: time, drawableSize: Self.size)
        }
        let oneOverE = Float(exp(-1.0))
        #expect(abs(last.onsetPulse - oneOverE) < 0.05, "pulse \(last.onsetPulse)")
    }

    @Test("The pressure-wave centre is the loudest band group's wisp")
    func pressureWaveCentre() {
        var state = NebulaState()
        // Treble loudest: bands 24..31 hot, the rest quiet.
        var bands = [Float](repeating: 0.05, count: 32)
        for index in 24 ..< 32 {
            bands[index] = 1.0
        }
        let uniforms = state.update(
            analysis: Self.analysis(bands: bands, onset: true, frameIndex: 1),
            time: Self.oneFrame,
            drawableSize: Self.size
        )
        #expect(uniforms.loudestWisp == 3, "loudest \(uniforms.loudestWisp)")
    }

    // MARK: - Band-group energies

    @Test("Group energies average contiguous quarters of the bands")
    func groupEnergyQuarters() {
        var bands = [Float](repeating: 0, count: 32)
        for index in 0 ..< 8 {
            bands[index] = 1.0 // bass group all-on
        }
        for index in 16 ..< 24 {
            bands[index] = 0.5 // high-mid group half-on
        }
        let energies = NebulaState.groupEnergies(bands: bands)
        #expect(abs(energies.x - 1.0) < 1e-6) // bass
        #expect(abs(energies.y - 0.0) < 1e-6) // low mids
        #expect(abs(energies.z - 0.5) < 1e-6) // high mids
        #expect(abs(energies.w - 0.0) < 1e-6) // treble
    }

    @Test("A zero-energy band group yields strength 0 and the base radius")
    func zeroEnergyGroup() {
        var state = NebulaState()
        // Only the bass group has energy; the other three groups are silent.
        var bands = [Float](repeating: 0, count: 32)
        for index in 0 ..< 8 {
            bands[index] = 1.0
        }
        let uniforms = state.update(
            analysis: Self.analysis(bands: bands, frameIndex: 1),
            time: Self.oneFrame,
            drawableSize: Self.size
        )
        #expect(uniforms.wispStrengths.x == 1.0)
        #expect(uniforms.wispStrengths.y == 0)
        #expect(uniforms.wispStrengths.z == 0)
        #expect(uniforms.wispStrengths.w == 0)
        // Silent group radius is exactly the base (no breathing).
        #expect(abs(uniforms.wispRadii.y - NebulaState.wispRadiusBase) < 1e-6)
        // The energised group breathes to base + gain.
        #expect(abs(uniforms.wispRadii.x - (NebulaState.wispRadiusBase + NebulaState.wispRadiusGain)) < 1e-6)
    }

    // MARK: - Wisp orbits

    @Test("Wisp positions are deterministic for a fixed flowTime")
    func wispOrbitDeterminism() {
        for index in 0 ..< 4 {
            let first = NebulaState.wispPosition(index: index, flowTime: 12.3456)
            let second = NebulaState.wispPosition(index: index, flowTime: 12.3456)
            #expect(first == second, "wisp \(index) not deterministic")
        }
    }

    @Test("Wisp positions stay within the unit rectangle across a long sweep")
    func wispOrbitBounds() {
        var flow = 0.0
        while flow < 200.0 {
            for index in 0 ..< 4 {
                let pos = NebulaState.wispPosition(index: index, flowTime: flow)
                #expect(abs(pos.x) <= NebulaState.unitBound, "wisp \(index) x out of bounds at \(flow)")
                #expect(abs(pos.y) <= NebulaState.unitBound, "wisp \(index) y out of bounds at \(flow)")
            }
            flow += 0.13
        }
    }

    @Test("The four wisps follow distinct orbits (paths do not coincide)")
    func wispOrbitsDistinct() {
        let flow = 7.0
        let positions = (0 ..< 4).map { NebulaState.wispPosition(index: $0, flowTime: flow) }
        for outer in 0 ..< 4 {
            for inner in (outer + 1) ..< 4 {
                #expect(positions[outer] != positions[inner], "wisps \(outer) and \(inner) coincide")
            }
        }
    }

    // MARK: - Warp amplitude modulation

    @Test("Warp amplitude is modulated +-25% by mid energy around the base")
    func warpAmpModulation() {
        var silentState = NebulaState()
        let silent = silentState.update(analysis: Self.analysis(midEnergy: 0, frameIndex: 1), time: 0, drawableSize: Self.size)
        // mid 0 -> base * (1 - 0.25); mid 1 -> base * (1 + 0.25); mid 0.5 -> base.
        #expect(abs(silent.warpAmp - NebulaState.warpAmpBase * 0.75) < 1e-4, "silent \(silent.warpAmp)")

        var loudState = NebulaState()
        let loud = loudState.update(analysis: Self.analysis(midEnergy: 1, frameIndex: 1), time: 0, drawableSize: Self.size)
        #expect(abs(loud.warpAmp - NebulaState.warpAmpBase * 1.25) < 1e-4, "loud \(loud.warpAmp)")

        var midState = NebulaState()
        let neutral = midState.update(analysis: Self.analysis(midEnergy: 0.5, frameIndex: 1), time: 0, drawableSize: Self.size)
        #expect(abs(neutral.warpAmp - NebulaState.warpAmpBase) < 1e-4, "neutral \(neutral.warpAmp)")
    }

    @Test("Centroid tints the LUT offset by centroid * 0.15")
    func centroidTint() {
        var state = NebulaState()
        let uniforms = state.update(analysis: Self.analysis(centroid: 0.8, frameIndex: 1), time: 0, drawableSize: Self.size)
        #expect(abs(uniforms.centroidTint - 0.8 * 0.15) < 1e-4, "tint \(uniforms.centroidTint)")
    }

    // MARK: - Golden uniform buffer

    @Test("A scripted sequence produces finite uniforms in documented ranges")
    func goldenUniforms() {
        var state = NebulaState()
        var bands = [Float](repeating: 0, count: 32)
        for index in bands.indices {
            bands[index] = Float(index) / 31
        }
        var captured = [NebulaUniforms]()
        for frame in 1 ... 120 {
            let onset = frame % 24 == 0
            let analysis = Self.analysis(
                bands: bands,
                centroid: 0.7,
                onset: onset,
                bassEnergy: 0.6,
                midEnergy: 0.4,
                frameIndex: UInt64(frame)
            )
            captured.append(state.update(analysis: analysis, time: Double(frame) * Self.oneFrame, drawableSize: Self.size))
        }
        for uniforms in captured {
            #expect(uniforms.flowTime.isFinite && !uniforms.flowTime.isNaN)
            #expect(uniforms.warpAmp.isFinite)
            #expect(uniforms.exposure >= 1.0 && uniforms.exposure <= 1.2 + 1e-4)
            #expect(uniforms.onsetPulse >= 0 && uniforms.onsetPulse <= 1.0 + 1e-6)
            #expect(uniforms.centroidTint >= 0 && uniforms.centroidTint <= 0.15 + 1e-6)
            #expect(uniforms.loudestWisp >= 0 && uniforms.loudestWisp <= 3)
            for component in 0 ..< 4 {
                #expect(uniforms.wispStrengths[component] >= 0 && uniforms.wispStrengths[component] <= 1.0 + 1e-6)
                #expect(uniforms.wispRadii[component] >= NebulaState.wispRadiusBase - 1e-6)
            }
            for wisp in [uniforms.wisp0, uniforms.wisp1, uniforms.wisp2, uniforms.wisp3] {
                #expect(abs(wisp.x) <= NebulaState.unitBound + 1e-4)
                #expect(abs(wisp.y) <= NebulaState.unitBound + 1e-4)
            }
        }
    }

    @Test("Packing the same state twice is identical (struct equality)")
    func packDeterminism() {
        var state = NebulaState()
        let analysis = Self.analysis(bands: nil, bassEnergy: 0.5, midEnergy: 0.3, frameIndex: 1)
        _ = state.update(analysis: analysis, time: Self.oneFrame, drawableSize: Self.size)
        let first = state.pack(analysis: analysis, drawableSize: Self.size)
        let second = state.pack(analysis: analysis, drawableSize: Self.size)
        #expect(first == second)
    }

    // MARK: - LUT correspondence

    @Test("The LUT first and last texels match rampStops", arguments: VisualizerPalette.allCases)
    func lutMatchesRampStops(palette: VisualizerPalette) {
        var lut = PaletteRampLUT(palette: palette)
        _ = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        let stops = PaletteResolver.rampStops(palette: palette, analysis: .silent, time: 0)
        #expect(lut.colors.first == ColorPacking.bgra(stops.first ?? .black))
        #expect(lut.colors.last == ColorPacking.bgra(stops.last ?? .black))
    }

    @Test("Static palettes never regenerate after the first build")
    func staticPaletteNoRegen() {
        var lut = PaletteRampLUT(palette: .thermal)
        let firstBuild = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        #expect(firstBuild)
        let secondCall = lut.rebuildIfNeeded(analysis: .silent, time: 10)
        #expect(!secondCall)
        let thirdCall = lut.rebuildIfNeeded(analysis: Self.analysis(centroid: 0.9, frameIndex: 5), time: 1000)
        #expect(!thirdCall)
    }

    @Test("Drift regenerates only once the base hue moves past the threshold")
    func driftRegenThreshold() {
        var lut = PaletteRampLUT(palette: .drift)
        let firstBuild = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        #expect(firstBuild)
        // A hair later: well under 1/256 of a 90 s cycle, so no rebuild.
        let hairLater = lut.rebuildIfNeeded(analysis: .silent, time: 0.05)
        #expect(!hairLater)
        // 1 s later moves the base hue 1/90 of a cycle, far past 1/256.
        let secondLater = lut.rebuildIfNeeded(analysis: .silent, time: 1.0)
        #expect(secondLater)
    }
}
