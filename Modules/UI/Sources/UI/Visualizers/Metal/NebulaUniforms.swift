import AudioEngine
import Foundation
import simd

// MARK: - NebulaUniforms

/// CPU mirror of the MSL `NebulaUniforms` (same field order, 96 bytes).
///
/// Every audio-reactive number the shader needs arrives here, packed on the CPU
/// from ``Analysis`` so the `.metal` file carries zero audio opinions. Fields are
/// grouped to a 16-byte alignment that matches the MSL struct exactly; the stride
/// is asserted in the tests so a silent misalignment (which renders as "the music
/// does nothing") is caught as a build-time failure, not a visual one.
///
/// Layout (byte offsets):
/// - 0: `drawableSize` (8), 8: `flowTime` (4), 12: `warpAmp` (4)
/// - 16: `exposure` (4), 20: `onsetPulse` (4), 24: `centroidTint` (4), 28: `loudestWisp` (4)
/// - 32: `wisp0` (8), 40: `wisp1` (8), 48: `wisp2` (8), 56: `wisp3` (8)
/// - 64: `wispStrengths` (16), 80: `wispRadii` (16) -> stride 96.
struct NebulaUniforms: Equatable {
    /// Drawable size in pixels; the shader derives its aspect ratio from this so
    /// the gas does not stretch as the render scale shrinks the drawable.
    var drawableSize: SIMD2<Float>
    /// The CPU-integrated flow clock that drives the gas churn and wisp orbits.
    var flowTime: Float
    /// Domain-warp amplitude, the base warp factor modulated +-25% by mid energy.
    var warpAmp: Float
    /// Brightness multiplier; 1.0 baseline, boosted up to 20% by the onset envelope.
    var exposure: Float
    /// Onset pressure-wave envelope, 0...1, decaying after each onset.
    var onsetPulse: Float
    /// LUT hue offset from the spectral centroid (`centroid * 0.15`).
    var centroidTint: Float
    /// Index (0...3) of the loudest wisp, the centre of the onset pressure wave.
    var loudestWisp: Float
    /// Wisp 0 centre in aspect-corrected UV.
    var wisp0: SIMD2<Float>
    /// Wisp 1 centre in aspect-corrected UV.
    var wisp1: SIMD2<Float>
    /// Wisp 2 centre in aspect-corrected UV.
    var wisp2: SIMD2<Float>
    /// Wisp 3 centre in aspect-corrected UV.
    var wisp3: SIMD2<Float>
    /// The four wisp strengths (band-group energies), packed for 16-byte alignment.
    var wispStrengths: SIMD4<Float>
    /// The four wisp blob radii, packed for 16-byte alignment.
    var wispRadii: SIMD4<Float>
}

// MARK: - NebulaState

/// The pure, fully unit-tested CPU core of the Nebula visualizer.
///
/// It owns everything audio-reactive: the `flowTime` integrator, the onset
/// envelope, the four Lissajous wisp orbits, the band-group energies that drive
/// wisp strength and radius, and the adaptive render-scale state machine. The
/// Metal renderer is a thin shell around `update(...)`; the shader is a pure
/// function of the packed ``NebulaUniforms``.
///
/// No Metal types appear here, so the whole motion model runs on a machine with
/// no GPU and is golden-buffer testable.
struct NebulaState {
    // MARK: - Tuning constants

    /// Baseline flow advance per second, keeping the gas alive in silence.
    static let flowBaseRate = 0.02
    /// How much bass energy adds to the flow rate (full bass churns ~16x faster).
    static let flowBassRate = 0.30
    /// How much the onset envelope adds to the flow rate.
    static let flowOnsetRate = 0.50
    /// Frame-to-frame `dt` clamp; a pause/resume gap cannot lurch the clock.
    static let maxDeltaTime = 0.1

    /// Onset decay time constant for the pressure wave and exposure boost.
    static let onsetTau: TimeInterval = 0.3
    /// Maximum exposure boost from a full onset envelope (20%).
    static let onsetExposureBoost: Float = 0.2

    /// Base domain-warp amplitude (the IQ `4.0` factor), modulated by mids.
    static let warpAmpBase: Float = 4.0
    /// Fraction the mid energy modulates the warp amplitude (+-25%).
    static let warpAmpModulation: Float = 0.25

    /// Centroid-to-LUT-offset gain.
    static let centroidTintGain: Float = 0.15

    /// Shared Lissajous orbit amplitude in UV (positions stay within +-this of centre).
    static let orbitAmplitude: Float = 0.42
    /// Base wisp radius in UV, before the energy-driven breathing.
    static let wispRadiusBase: Float = 0.18
    /// Extra wisp radius at full group energy.
    static let wispRadiusGain: Float = 0.14

    // MARK: - Lissajous orbit definitions

    /// Per-wisp co-prime-ish frequency pairs and phase offsets so the four orbits
    /// never visibly repeat together. Indexed by band group: 0 bass, 1 low mids,
    /// 2 high mids, 3 treble.
    private struct Orbit {
        let freqX: Float
        let freqY: Float
        let phaseX: Float
        let phaseY: Float
        let centre: SIMD2<Float>
    }

    private static let orbits: [Orbit] = [
        Orbit(freqX: 0.7, freqY: 1.1, phaseX: 0.0, phaseY: 1.7, centre: SIMD2(-0.30, -0.25)),
        Orbit(freqX: 1.3, freqY: 0.9, phaseX: 2.1, phaseY: 0.4, centre: SIMD2(0.32, -0.28)),
        Orbit(freqX: 1.7, freqY: 1.3, phaseX: 0.9, phaseY: 3.0, centre: SIMD2(-0.28, 0.30)),
        Orbit(freqX: 1.1, freqY: 1.9, phaseX: 3.4, phaseY: 1.2, centre: SIMD2(0.34, 0.26)),
    ]

    /// Half-extent the orbit centres plus amplitude must stay inside; the unit
    /// rectangle test relies on this bound holding.
    static let unitBound: Float = 1.0

    // MARK: - State

    /// The integrated flow clock. Monotonically non-decreasing.
    private(set) var flowTime: Double = 0
    private var onsetEnvelope = OnsetEnvelope(tau: Self.onsetTau)
    private var lastTime: TimeInterval?

    init() {}

    // MARK: - Band-group energies

    /// The four band-group energies (bass, low mids, high mids, treble) as the
    /// mean of each contiguous quarter of the 32 bands, clamped 0...1. Returned in
    /// orbit/wisp order. A group whose bands are all zero yields exactly 0.
    static func groupEnergies(bands: [Float]) -> SIMD4<Float> {
        var result = SIMD4<Float>(repeating: 0)
        let count = bands.count
        guard count > 0 else { return result }
        let quarter = max(1, count / 4)
        for group in 0 ..< 4 {
            let start = group * quarter
            let end = group == 3 ? count : min(count, start + quarter)
            guard start < end else { continue }
            var sum: Float = 0
            for index in start ..< end {
                sum += bands[index]
            }
            let mean = sum / Float(end - start)
            result[group] = min(1, max(0, mean))
        }
        return result
    }

    // MARK: - Wisp orbits

    /// Wisp `index`'s centre for a given `flowTime`, in aspect-corrected UV.
    /// Deterministic for a fixed `flowTime` and always within the unit rectangle
    /// (`abs(component) <= unitBound`).
    static func wispPosition(index: Int, flowTime: Double) -> SIMD2<Float> {
        let orbit = Self.orbits[index]
        let time = Float(flowTime)
        let posX = orbit.centre.x + Self.orbitAmplitude * sin(orbit.freqX * time + orbit.phaseX)
        let posY = orbit.centre.y + Self.orbitAmplitude * sin(orbit.freqY * time + orbit.phaseY)
        return SIMD2(posX, posY)
    }

    // MARK: - Per-frame update

    /// Advances the flow clock, onset envelope, orbits, and render scale by one
    /// frame, then returns the fully packed uniforms. `drawableSize` is in pixels.
    mutating func update(
        analysis: Analysis,
        time: TimeInterval,
        drawableSize: CGSize
    ) -> NebulaUniforms {
        let dt = self.lastTime.map { min(max(0, time - $0), Self.maxDeltaTime) } ?? 0
        self.lastTime = time

        // Onset envelope first; the flow rate reads its post-decay value.
        self.onsetEnvelope.update(analysis: analysis, time: time)
        let onset = self.onsetEnvelope.value

        let bass = Double(min(1, max(0, analysis.bassEnergy)))
        let flowRate = Self.flowBaseRate + Self.flowBassRate * bass + Self.flowOnsetRate * onset
        self.flowTime += dt * flowRate

        return self.pack(analysis: analysis, drawableSize: drawableSize)
    }

    /// Packs the current state plus this frame's analysis into uniforms, without
    /// advancing any clock. Exposed so snapshot tests can pin `flowTime` and the
    /// envelope and pack a fully deterministic frame.
    func pack(analysis: Analysis, drawableSize: CGSize) -> NebulaUniforms {
        let energies = Self.groupEnergies(bands: analysis.bands)
        let onset = Float(self.onsetEnvelope.value)

        let mid = min(1, max(0, analysis.midEnergy))
        let warpAmp = Self.warpAmpBase * (1 + Self.warpAmpModulation * (2 * mid - 1))
        let exposure = 1 + Self.onsetExposureBoost * onset
        let centroidTint = min(1, max(0, analysis.centroid)) * Self.centroidTintGain

        var positions = [SIMD2<Float>](repeating: .zero, count: 4)
        var radii = SIMD4<Float>(repeating: 0)
        var loudest = 0
        var loudestEnergy: Float = -1
        for index in 0 ..< 4 {
            positions[index] = Self.wispPosition(index: index, flowTime: self.flowTime)
            let energy = energies[index]
            radii[index] = Self.wispRadiusBase + Self.wispRadiusGain * energy
            if energy > loudestEnergy {
                loudestEnergy = energy
                loudest = index
            }
        }

        return NebulaUniforms(
            drawableSize: SIMD2(Float(max(1, drawableSize.width)), Float(max(1, drawableSize.height))),
            flowTime: Float(self.flowTime),
            warpAmp: warpAmp,
            exposure: exposure,
            onsetPulse: onset,
            centroidTint: centroidTint,
            loudestWisp: Float(loudest),
            wisp0: positions[0],
            wisp1: positions[1],
            wisp2: positions[2],
            wisp3: positions[3],
            wispStrengths: energies,
            wispRadii: radii
        )
    }
}
