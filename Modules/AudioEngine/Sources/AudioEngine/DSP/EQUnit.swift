import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

// MARK: - EQUnit

/// 10-band parametric EQ using `AVAudioUnitEQ`.
///
/// Bands are placed at ISO 1/3-octave centre frequencies:
/// 31.5 Hz (low shelf), 63, 125, 250, 500, 1k, 2k, 4k, 8k Hz (parametric), 16k Hz (high shelf).
/// Gain range per band: ±12 dB. Overall output gain: ±12 dB.
///
/// `bypass = true` routes audio around the EQ completely with zero floating-point artefacts.
public final class EQUnit: @unchecked Sendable {
    // @unchecked: AVAudioUnitEQ lacks Sendable; safety provided by AudioEngine actor.

    /// ISO 1/3-octave centre frequencies for the 10 bands (Hz).
    public static let isoFrequencies: [Float] = [
        31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    ]

    /// The underlying EQ node. Connect this in the audio graph.
    let node: AVAudioUnitEQ

    public init() {
        self.node = AVAudioUnitEQ(numberOfBands: 10)
        self.configureDefaultBands()
    }

    // MARK: - Public API

    /// Apply a preset's band gains and output gain.
    public func apply(preset: EQPreset) {
        for (i, db) in preset.bandGainsDB.enumerated() where i < self.node.bands.count {
            node.bands[i].gain = Float(db)
        }
        self.node.globalGain = Float(preset.outputGainDB)
    }

    /// Apply individual band gains (must have exactly 10 values).
    public func setBandGains(_ gains: [Double]) {
        for (i, db) in gains.enumerated() where i < self.node.bands.count {
            node.bands[i].gain = Float(db)
        }
    }

    /// Reset all bands and global gain to 0 dB, and flush IIR delay lines.
    ///
    /// `AudioUnitReset` zeroes all internal biquad delay buffers.  Call this
    /// before un-bypassing so the filter re-starts from a known-zero state
    /// rather than from stale samples held from the previous active period.
    public func reset() {
        self.node.bands.forEach { $0.gain = 0 }
        self.node.globalGain = 0
        // Flush IIR delay lines — must be called while the unit is still
        // bypassed (no audio flowing through it) to be a silent operation.
        AudioUnitReset(self.node.audioUnit, kAudioUnitScope_Global, 0)
    }

    /// When `true`, the EQ node is completely bypassed (zero floating-point noise).
    public var bypass: Bool {
        get { self.node.bypass }
        set { self.node.bypass = newValue }
    }

    // MARK: - Private

    private func configureDefaultBands() {
        let freqs = Self.isoFrequencies
        for (i, band) in self.node.bands.enumerated() {
            band.frequency = freqs[i]
            band.gain = 0
            band.bandwidth = 1.0 // 1-octave Q bandwidth
            band.bypass = false
            switch i {
            case 0:
                band.filterType = .lowShelf

            case 9:
                band.filterType = .highShelf

            default:
                band.filterType = .parametric
            }
        }
        self.node.globalGain = 0
    }
}
