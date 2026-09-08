@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - AudioEngine + Gapless public API

/// The gapless preload entry points. Split from `AudioEngine.swift` to keep
/// that file inside the lint length limit. The state these touch stays in
/// the actor's "Gapless state" section, and the transition itself lives in
/// `AudioEngine+Gapless.swift` next to the pump handling.
public extension AudioEngine {
    /// Pre-schedule the next track's audio buffers onto the current player node.
    ///
    /// Call this ~5 s before the current track ends. The engine will NOT stop the player
    /// when the current track's decoder hits EOF; instead it calls `onTransition`, resets
    /// timing, and continues playing seamlessly.
    ///
    /// - Parameters:
    ///   - url: File URL of the next track. Must be the same sample rate and channel count
    ///          as the current track (check `sourceFormat` first via `FormatBridge`).
    ///   - onTransition: Invoked on the `AudioEngine` actor when the transition occurs.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    func enableGaplessNext(url: URL, onTransition: @Sendable @escaping () -> Void) async throws {
        // Cancel any previous pending-next setup.
        await self.pendingNextPump?.stop()
        if let prev = pendingNextDecoder {
            await prev.close()
        }
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil

        let dec = try DecoderFactory.make(for: url)
        let nextDuration = dec.duration

        let sampleRate = self.graph.outputSampleRate
        guard let outputFmt = StereoLayout.format(sampleRate: sampleRate) else {
            throw AudioEngineError.outputDeviceUnavailable
        }

        let playerNode = self.graph.playerNode
        let nextPump = try BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt
        )

        self.pendingNextPump = nextPump
        self.pendingNextDuration = nextDuration
        self.pendingNextDecoder = dec
        self.pendingNextTransition = onTransition

        // Pump is started in `performGaplessTransition` (not here) so its
        // scheduleBuffer calls land strictly after the outgoing pump's tail in
        // the shared AVAudioPlayerNode FIFO; otherwise they interleave.
        self.log.debug("engine.gapless.prefetch", ["url": url.lastPathComponent])
    }

    /// Cancel any active gapless preload without stopping the player.
    func cancelGaplessNext() async {
        await self.pendingNextPump?.stop()
        if let prev = pendingNextDecoder {
            await prev.close()
        }
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        self.log.debug("engine.gapless.cancelled")
    }
}
