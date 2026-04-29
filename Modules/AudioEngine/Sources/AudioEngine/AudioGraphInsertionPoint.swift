@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioGraphInsertionPoint

/// Abstraction over the engine's DSP insertion point so later phases (EQ, taps,
/// visualizers) can attach to the chain without depending on a concrete
/// `DSPChain`.  The audio engine vends one of these via
/// ``AudioEngine/insertionPoint``.
///
/// Conformers must be safe to consume from any actor — `AudioEngine` mediates
/// access in practice.
public protocol AudioGraphInsertionPoint: Sendable {
    /// Apply a complete DSP state snapshot.
    func applyDSPState(_ state: DSPState) async

    /// Apply a single ReplayGain compensation in dB.
    func applyReplayGain(db: Double) async

    /// Set the playback rate (1.0 = normal). Pitch is preserved.
    func setRate(_ rate: Float) async
}
