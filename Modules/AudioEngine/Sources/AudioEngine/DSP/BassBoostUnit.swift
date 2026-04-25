@preconcurrency import AVFoundation
import Foundation

// MARK: - BassBoostUnit

/// A dedicated low-shelf bass-boost stage.
///
/// Uses a second `AVAudioUnitEQ` instance (separate from the main EQ) so that bass-boost
/// settings are decoupled from EQ presets and can be toggled independently.
///
/// Fixed shelf frequency: 80 Hz. Gain range: 0–12 dB. Off by default (bypass = true).
public final class BassBoostUnit: @unchecked Sendable {
    // @unchecked: AVAudioUnitEQ lacks Sendable; safety provided by AudioEngine actor.

    /// Fixed low-shelf frequency.
    public static let shelfFrequency: Float = 80

    /// The underlying EQ node. Connect this in the audio graph.
    let node: AVAudioUnitEQ

    public init() {
        self.node = AVAudioUnitEQ(numberOfBands: 1)
        self.configureBand()
    }

    // MARK: - Public API

    /// Set the bass boost gain in dB (0 = off, values outside 0…12 are clamped).
    public func setGainDB(_ db: Double) {
        let clamped = max(0, min(12, db))
        self.node.bands.first?.gain = Float(clamped)
        self.node.bypass = clamped == 0
    }

    /// Current bass boost gain in dB as seen by the EQ band.
    public var gainDB: Double {
        Double(self.node.bands.first?.gain ?? 0)
    }

    // MARK: - Private

    private func configureBand() {
        guard let band = node.bands.first else { return }
        band.filterType = .lowShelf
        band.frequency = Self.shelfFrequency
        band.gain = 0
        band.bandwidth = 0.5
        band.bypass = false
        self.node.bypass = true // off by default
    }
}
