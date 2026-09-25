import Accelerate

// @preconcurrency: AVAudioPCMBuffer lacks Sendable; the caller owns every buffer
// it passes in for the duration of the call.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

// MARK: - CrossfadeMix

/// Equal-power mixing of an outgoing and an incoming track during a crossfade
/// (ADR-095). Pure: no graph, no actors, no state. The buffer pump calls it once
/// per scheduled buffer while an overlap is running.
///
/// Both tracks are already in the canonical output format when they arrive
/// here (each pump source has its own `FormatConverter`), so the mix is a
/// per-channel multiply-add and never resamples.
enum CrossfadeMix {
    /// The equal-power gain pair for overlap frame `frame` of an overlap
    /// `length` frames long: `cos` for the outgoing track, `sin` for the
    /// incoming one, so `outgoing² + incoming² == 1` on every frame.
    ///
    /// Outside the overlap the pair is clamped: at or before frame 0 it is
    /// `(1, 0)` (all outgoing), at or after `length` it is `(0, 1)` (all
    /// incoming). A non-positive `length` has no overlap at all, so it is
    /// `(0, 1)` for every frame.
    static func gains(atFrame frame: Int, of length: Int) -> (outgoing: Float, incoming: Float) {
        guard length > 0, frame < length else { return (0, 1) }
        guard frame > 0 else { return (1, 0) }
        let angle = Double(frame) / Double(length) * Double.pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Mix `outgoing` and `incoming` into `output`:
    /// `output[i] = outgoing[i] * gOut(startFrame + i) + incoming[i] * gIn(startFrame + i)`
    /// for every channel, where the gains come from `gains(atFrame:of:)`.
    ///
    /// `incoming.frameLength` sets the number of frames mixed and becomes
    /// `output.frameLength`. A `nil` outgoing buffer, or one shorter than the
    /// incoming one (the outgoing track ended early), contributes silence for
    /// the frames it does not have. `startFrame` is the overlap frame of the
    /// first frame in these buffers, so the curve continues across buffers.
    ///
    /// The sum is not clamped: two loud tracks can exceed full scale here, and
    /// the limiter downstream catches it (ADR-095, Gotchas).
    ///
    /// - Throws: `AudioEngineError.crossfadeBufferMismatch` when the buffers
    ///   do not share one non-interleaved Float32 format, or when `output`
    ///   cannot hold `incoming.frameLength` frames.
    static func mix(
        outgoing: AVAudioPCMBuffer?,
        incoming: AVAudioPCMBuffer,
        into output: AVAudioPCMBuffer,
        startFrame: Int,
        length: Int
    ) throws {
        try self.validate(outgoing: outgoing, incoming: incoming, output: output)

        let frames = Int(incoming.frameLength)
        output.frameLength = incoming.frameLength
        guard frames > 0 else { return }

        guard let incomingData = incoming.floatChannelData,
              let outputData = output.floatChannelData else {
            throw AudioEngineError.crossfadeBufferMismatch(reason: "a buffer has no float channel data")
        }
        let outgoingData = outgoing?.floatChannelData
        let outgoingFrames = outgoingData == nil ? 0 : min(Int(outgoing?.frameLength ?? 0), frames)

        // One gain ramp per buffer, built from the scalar pair so the vector
        // path and `gains(atFrame:of:)` can never disagree.
        var outgoingGain = [Float](repeating: 0, count: frames)
        var incomingGain = [Float](repeating: 0, count: frames)
        for index in 0 ..< frames {
            let pair = self.gains(atFrame: startFrame + index, of: length)
            outgoingGain[index] = pair.outgoing
            incomingGain[index] = pair.incoming
        }

        outgoingGain.withUnsafeBufferPointer { gOut in
            incomingGain.withUnsafeBufferPointer { gIn in
                for channel in 0 ..< Int(incoming.format.channelCount) {
                    let destination = UnsafeMutableBufferPointer(start: outputData[channel], count: frames)
                    let incomingSamples = UnsafeBufferPointer(start: incomingData[channel], count: frames)

                    // Frames where both tracks exist: outgoing * gOut + incoming * gIn.
                    if let outgoingData, outgoingFrames > 0 {
                        let outgoingSamples = UnsafeBufferPointer(start: outgoingData[channel], count: outgoingFrames)
                        var head = UnsafeMutableBufferPointer(rebasing: destination[0 ..< outgoingFrames])
                        vDSP.add(
                            multiplication: (
                                outgoingSamples,
                                UnsafeBufferPointer(rebasing: gOut[0 ..< outgoingFrames])
                            ),
                            multiplication: (
                                UnsafeBufferPointer(rebasing: incomingSamples[0 ..< outgoingFrames]),
                                UnsafeBufferPointer(rebasing: gIn[0 ..< outgoingFrames])
                            ),
                            result: &head
                        )
                    }

                    // Frames the outgoing track no longer has: incoming * gIn.
                    if outgoingFrames < frames {
                        var tail = UnsafeMutableBufferPointer(rebasing: destination[outgoingFrames ..< frames])
                        vDSP.multiply(
                            UnsafeBufferPointer(rebasing: incomingSamples[outgoingFrames ..< frames]),
                            UnsafeBufferPointer(rebasing: gIn[outgoingFrames ..< frames]),
                            result: &tail
                        )
                    }
                }
            }
        }
    }

    // MARK: - Private

    private static func validate(
        outgoing: AVAudioPCMBuffer?,
        incoming: AVAudioPCMBuffer,
        output: AVAudioPCMBuffer
    ) throws {
        let format = incoming.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioEngineError.crossfadeBufferMismatch(
                reason: "incoming format is not non-interleaved Float32: \(format)"
            )
        }
        guard output.format == format else {
            throw AudioEngineError.crossfadeBufferMismatch(
                reason: "output format \(output.format) differs from incoming \(format)"
            )
        }
        if let outgoing, outgoing.format != format {
            throw AudioEngineError.crossfadeBufferMismatch(
                reason: "outgoing format \(outgoing.format) differs from incoming \(format)"
            )
        }
        guard output.frameCapacity >= incoming.frameLength else {
            throw AudioEngineError.crossfadeBufferMismatch(
                reason: "output holds \(output.frameCapacity) frames, incoming has \(incoming.frameLength)"
            )
        }
    }
}
