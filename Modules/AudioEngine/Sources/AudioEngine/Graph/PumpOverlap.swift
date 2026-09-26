import Foundation

// MARK: - PumpOverlap (ADR-095)

/// An armed or running crossfade in a `BufferPump`. Split from
/// `BufferPump+Overlap.swift`, which drives it, to keep that file inside the
/// lint length limit.
///
/// A plain gapless boundary is an overlap of length 0 (#574): it never mixes,
/// it plays the outgoing track to its end and hands over, and its transition
/// fires when the incoming track is heard, as a crossfade's does.
struct PumpOverlap {
    let incoming: PumpSource
    /// The armed overlap length in output frames. 0 for a gapless hand-over.
    let lengthFrames: Int
    let onTransition: @Sendable () -> Void
    var phase: PumpOverlapPhase
    /// Sequence number of the buffer whose completion means the incoming
    /// track is heard. `nil` until the mix (or hand-over) starts.
    var transitionAfter: Int?

    init(incoming: PumpSource, lengthFrames: Int, onTransition: @Sendable @escaping () -> Void) {
        self.incoming = incoming
        self.lengthFrames = lengthFrames
        self.onTransition = onTransition
        self.phase = Self.armedPhase(lengthFrames: lengthFrames)
    }

    /// Where an overlap of `lengthFrames` starts, and starts again after a
    /// seek: waiting for its boundary, or, with nothing to mix, going
    /// straight to the gapless hand-over at the outgoing track's end.
    static func armedPhase(lengthFrames: Int) -> PumpOverlapPhase {
        lengthFrames > 0 ? .armed : .armedLate
    }
}

/// Where a `PumpOverlap` stands.
enum PumpOverlapPhase {
    /// Waiting for the boundary frame.
    case armed
    /// Past the boundary with too little of the outgoing track left to mix
    /// (a seek into the last second, or a late arm), or a gapless hand-over,
    /// which never mixes. The incoming track follows the outgoing one's end
    /// with no mix, gapless.
    case armedLate
    /// Mixed buffers are being scheduled.
    case mixing(PumpOverlapMix)
    /// The incoming track is `current`, but the transition is not heard yet.
    /// The outgoing source is kept, unread, so a seek can still go back to it.
    case handedOver(outgoing: PumpSource)
}

/// The progress of a running mix.
struct PumpOverlapMix {
    /// Frames in this mix: the armed length, or less when it started late.
    let length: Int
    var mixed = 0
    var outgoingSupplied = 0
    var outgoingEnded = false
}
