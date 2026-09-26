@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - AudioEngine + Gapless public API

/// The gapless and crossfade preload entry points. Split from
/// `AudioEngine.swift` to keep that file inside the lint length limit. The
/// state these touch stays in the actor's "Gapless state" section, and the
/// transitions live in `AudioEngine+Gapless.swift` next to the pump handling.
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
    ///   - replayGain: The next track's ReplayGain facts; `nil` plays it as it is.
    ///   - onTransition: Invoked on the `AudioEngine` actor when the transition occurs.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    func enableGaplessNext(
        url: URL,
        replayGain: TrackReplayGain? = nil,
        onTransition: @Sendable @escaping () -> Void
    ) async throws {
        // Cancel any previous pending-next setup.
        await self.cancelGaplessNext()
        let dec = try DecoderFactory.make(for: url)
        try self.installGaplessNext(decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition)
    }

    /// Arm a crossfade into the next track: during the last seconds of the
    /// current track, the next one fades in while the current one fades out,
    /// both heard at once (ADR-095).
    ///
    /// The overlap is `min(overlapSeconds, current / 2, next / 2)`. When that
    /// is shorter than one second, or the current track is a CUE segment, or
    /// nothing is playing, the boundary falls back to the plain gapless
    /// preload, with the same `onTransition`.
    ///
    /// `onTransition` runs when the listener starts to hear the next track:
    /// when its first mixed frame plays, not when it is scheduled.
    ///
    /// Each track keeps its own ReplayGain through the mix: `replayGain` is
    /// the next track's facts, `nil` to play it as it is.
    ///
    /// - Returns: `true` when a crossfade is armed, `false` when the boundary
    ///   fell back to gapless.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    @discardableResult
    func enableCrossfadeNext(
        url: URL,
        overlapSeconds: TimeInterval,
        replayGain: TrackReplayGain? = nil,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> Bool {
        await self.cancelGaplessNext()
        let dec = try DecoderFactory.make(for: url)

        guard let pump = self.pump, self.segmentEndTime == nil, self.segmentStart == 0,
              let length = CrossfadeMix.overlapSeconds(
                  setting: overlapSeconds, outgoing: self._duration, incoming: dec.duration
              ) else {
            self.log.debug("crossfade.disarmed", [
                "reason": self.pump == nil ? "noPump" : "tooShortOrSegment",
                "next": url.lastPathComponent,
            ])
            try self.installGaplessNext(decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition)
            return false
        }

        let token = UUID()
        let pumpID = pump.id
        // [weak self]: the pump stores this closure for the whole overlap, so
        // a strong capture would form the engine ⇄ pump cycle play() avoids.
        let armed = try await pump.armOverlap(
            decoder: dec,
            lengthSeconds: length,
            gain: self.replayGainLinear(for: replayGain)
        ) { [weak self] in
            Task { await self?.handleCrossfadeTransition(token: token, firedBy: pumpID) }
        }
        guard armed else {
            self.log.debug("crossfade.disarmed", ["reason": "pumpRefused", "next": url.lastPathComponent])
            try self.installGaplessNext(decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition)
            return false
        }
        // A load or stop ran during the await and stopped that pump, which
        // closed the decoder: there is no boundary left to prepare.
        guard pumpID == self.pump?.id else {
            self.log.debug("crossfade.disarmed", ["reason": "pumpReplaced", "next": url.lastPathComponent])
            return false
        }
        self.pendingCrossfade = PendingCrossfade(
            token: token, decoder: dec, duration: dec.duration, replayGain: replayGain, transition: onTransition
        )
        self.log.debug("crossfade.armed", [
            "lengthMs": Int((length * 1000).rounded()), "next": url.lastPathComponent,
        ])
        return true
    }

    /// Cancel any active gapless preload or armed crossfade without stopping
    /// the player. A crossfade that has started mixing is past recall: it
    /// completes, and its transition still fires.
    func cancelGaplessNext() async {
        await self.pendingNextPump?.stop()
        if let prev = pendingNextDecoder {
            await prev.close()
        }
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        self.pendingNextReplayGain = nil
        await self.disarmCrossfade()
        self.log.debug("engine.gapless.cancelled")
    }
}

// MARK: - Internal helpers

extension AudioEngine {
    /// Build the pending pump for a gapless handoff to `decoder`'s track. Its
    /// feed starts in `performGaplessTransition`, not here.
    func installGaplessNext(
        decoder dec: any Decoder,
        url: URL,
        replayGain: TrackReplayGain?,
        onTransition: @Sendable @escaping () -> Void
    ) throws {
        let sampleRate = self.graph.outputSampleRate
        guard let outputFmt = StereoLayout.format(sampleRate: sampleRate) else {
            throw AudioEngineError.outputDeviceUnavailable
        }

        let playerNode = self.graph.playerNode
        let nextPump = try BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt,
            gain: self.replayGainLinear(for: replayGain)
        )

        self.pendingNextPump = nextPump
        self.pendingNextReplayGain = replayGain
        self.pendingNextDuration = dec.duration
        self.pendingNextDecoder = dec
        self.pendingNextTransition = onTransition

        // Pump is started in `performGaplessTransition` (not here) so its
        // scheduleBuffer calls land strictly after the outgoing pump's tail in
        // the shared AVAudioPlayerNode FIFO; otherwise they interleave.
        self.log.debug("engine.gapless.prefetch", ["url": url.lastPathComponent])
    }

    /// Ask the pump to drop an armed crossfade. Keeps it when the pump says
    /// it is too late, so the coming transition is still handled.
    func disarmCrossfade() async {
        guard let pending = self.pendingCrossfade else { return }
        let result = await self.pump?.disarmOverlap() ?? .nothingArmed
        if result == .tooLate {
            self.log.debug("crossfade.disarm.tooLate")
            return
        }
        // The await above let other work run: only drop the same arm.
        guard self.pendingCrossfade?.token == pending.token else { return }
        await self.dropPendingCrossfade(reason: "cancelled")
    }
}
