@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - NextTrackPreparation

/// How the engine prepared the boundary into the next track (ADR-095, #574).
public enum NextTrackPreparation: Sendable, Equatable {
    /// The next track fades in over the end of this one, mixed in the one pump.
    case crossfade
    /// The next track follows this one's last frame in the same pump, gapless.
    case handover
    /// The next track has a pump of its own, started when this one's feed
    /// ends. Its transition fires about 0.8 s before it is heard, and a
    /// spurious end can follow the pump swap. Only when the playing pump
    /// cannot take the next track: nothing is playing yet, or a CUE segment.
    case separatePump
    /// Nothing is prepared: a load or stop replaced the playing pump while
    /// the next track was being armed.
    case cancelled

    /// Whether the transition fires when the next track is first heard, with
    /// no pump swap after it.
    public var firesWhenHeard: Bool {
        self == .crossfade || self == .handover
    }
}

// MARK: - AudioEngine + Gapless public API

/// The gapless and crossfade preload entry points. Split from
/// `AudioEngine.swift` to keep that file inside the lint length limit. The
/// state these touch stays in the actor's "Gapless state" section, and the
/// transitions live in `AudioEngine+Gapless.swift` next to the pump handling.
public extension AudioEngine {
    /// Prepare the next track to follow the current one with no gap.
    ///
    /// Call this ~5 s before the current track ends. The playing pump reads
    /// the current track to its last frame and then the next one, on the one
    /// player node. `onTransition` runs when the listener starts to hear the
    /// next track: when the current track's last buffer has played, not when
    /// its decoder reaches the end, about 0.8 s earlier (#574).
    ///
    /// When the pump cannot take the next track (nothing is playing yet, or
    /// the current track is a CUE segment) it gets a pump of its own instead,
    /// started when this one's feed ends (`.separatePump`).
    ///
    /// - Parameters:
    ///   - url: File URL of the next track.
    ///   - replayGain: The next track's ReplayGain facts; `nil` plays it as it is.
    ///   - onTransition: Invoked on the `AudioEngine` actor when the transition occurs.
    /// - Returns: How the boundary was prepared.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    @discardableResult
    func enableGaplessNext(
        url: URL,
        replayGain: TrackReplayGain? = nil,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> NextTrackPreparation {
        // Cancel any previous pending-next setup.
        await self.cancelGaplessNext()
        let dec = try DecoderFactory.make(for: url)
        return try await self.prepareGaplessNext(
            decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition
        )
    }

    /// Arm a crossfade into the next track: during the last seconds of the
    /// current track, the next one fades in while the current one fades out,
    /// both heard at once (ADR-095).
    ///
    /// The overlap is `min(overlapSeconds, current / 2, next / 2)`. When that
    /// is shorter than one second, or the current track is a CUE segment, or
    /// nothing is playing, the boundary falls back to gapless, as
    /// `enableGaplessNext` prepares it, with the same `onTransition`.
    ///
    /// `onTransition` runs when the listener starts to hear the next track:
    /// when its first mixed frame plays, not when it is scheduled.
    ///
    /// Each track keeps its own ReplayGain through the mix: `replayGain` is
    /// the next track's facts, `nil` to play it as it is.
    ///
    /// - Returns: `.crossfade` when a crossfade is armed, else how the
    ///   gapless fallback was prepared.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    @discardableResult
    func enableCrossfadeNext(
        url: URL,
        overlapSeconds: TimeInterval,
        replayGain: TrackReplayGain? = nil,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> NextTrackPreparation {
        await self.cancelGaplessNext()
        let dec = try DecoderFactory.make(for: url)

        guard let length = CrossfadeMix.overlapSeconds(
            setting: overlapSeconds, outgoing: self._duration, incoming: dec.duration
        ) else {
            self.log.debug("crossfade.disarmed", ["reason": "tooShort", "next": url.lastPathComponent])
            return try await self.prepareGaplessNext(
                decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition
            )
        }

        let result = try await self.armInPump(
            decoder: dec, url: url, lengthSeconds: length, replayGain: replayGain, onTransition: onTransition
        )
        switch result {
        case .armed:
            self.log.debug("crossfade.armed", [
                "lengthMs": Int((length * 1000).rounded()), "next": url.lastPathComponent,
            ])
            return .crossfade

        case .refused:
            // The same conditions refuse a gapless hand-over, so the next
            // track gets its own pump.
            self.log.debug("crossfade.disarmed", ["reason": "pumpRefused", "next": url.lastPathComponent])
            try self.installGaplessNext(decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition)
            return .separatePump

        case .pumpReplaced:
            self.log.debug("crossfade.disarmed", ["reason": "pumpReplaced", "next": url.lastPathComponent])
            return .cancelled
        }
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

/// What `armInPump` did.
enum PumpArmResult {
    /// The playing pump holds the next track; `pendingCrossfade` is set.
    case armed
    /// The pump cannot take it: none is playing, a CUE segment plays, or it
    /// has ended or is mid-transition. The decoder is untouched.
    case refused
    /// A load or stop replaced the pump during the arm and closed the decoder.
    case pumpReplaced
}

extension AudioEngine {
    /// Gapless into `decoder`'s track: a hand-over in the playing pump when it
    /// can take one, else a pump of its own.
    func prepareGaplessNext(
        decoder dec: any Decoder,
        url: URL,
        replayGain: TrackReplayGain?,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> NextTrackPreparation {
        let result = try await self.armInPump(
            decoder: dec, url: url, lengthSeconds: 0, replayGain: replayGain, onTransition: onTransition
        )
        switch result {
        case .armed:
            self.log.debug("gapless.handover.armed", ["next": url.lastPathComponent])
            return .handover

        case .refused:
            try self.installGaplessNext(decoder: dec, url: url, replayGain: replayGain, onTransition: onTransition)
            return .separatePump

        case .pumpReplaced:
            self.log.debug("gapless.handover.cancelled", ["reason": "pumpReplaced", "next": url.lastPathComponent])
            return .cancelled
        }
    }

    /// Arm the playing pump to move on to `decoder`'s track: a crossfade
    /// `lengthSeconds` long, or a gapless hand-over at 0 (ADR-095, #574).
    /// Either way the pump reports the moment the next track is heard, and
    /// `handleCrossfadeTransition` makes it the engine's track.
    func armInPump(
        decoder dec: any Decoder,
        url: URL,
        lengthSeconds: TimeInterval,
        replayGain: TrackReplayGain?,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> PumpArmResult {
        guard let pump = self.pump, self.segmentEndTime == nil, self.segmentStart == 0 else {
            self.log.debug("pump.arm.refused", ["reason": self.pump == nil ? "noPump" : "segment"])
            return .refused
        }
        let token = UUID()
        let pumpID = pump.id
        // [weak self]: the pump stores this closure until the transition, so
        // a strong capture would form the engine ⇄ pump cycle play() avoids.
        let armed = try await pump.armOverlap(
            decoder: dec,
            lengthSeconds: lengthSeconds,
            gain: self.replayGainLinear(for: replayGain)
        ) { [weak self] in
            Task { await self?.handleCrossfadeTransition(token: token, firedBy: pumpID) }
        }
        guard armed else { return .refused }
        // A load or stop ran during the await and stopped that pump, which
        // closed the decoder: there is no boundary left to prepare.
        guard pumpID == self.pump?.id else { return .pumpReplaced }
        self.pendingCrossfade = PendingCrossfade(
            token: token,
            decoder: dec,
            duration: dec.duration,
            url: url,
            lengthSeconds: lengthSeconds,
            replayGain: replayGain,
            transition: onTransition
        )
        return .armed
    }

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
