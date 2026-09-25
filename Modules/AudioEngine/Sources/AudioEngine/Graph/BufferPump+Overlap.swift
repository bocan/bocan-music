// @preconcurrency: AVAudioPCMBuffer lacks Sendable; every buffer here is
// created and consumed on the pump's executor.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

// MARK: - BufferPump + Overlap (ADR-095)

/// The crossfade: during the last seconds of the current track the pump reads
/// the next track too, mixes the two with equal-power gains, and schedules the
/// mixed buffers on the one player node. Nothing is ever scheduled on the node
/// directly from the incoming track while the outgoing one still plays: the
/// node plays buffers in order, so that would put the new track after the old
/// one, which is the bug this replaces (#567).
///
/// The phases, in order: armed (waiting for the boundary frame), mixing, then
/// handed over (the incoming track is `current`). The transition, the moment
/// the listener starts to hear the incoming track, is the completion of the
/// last buffer scheduled before the first mixed one. It is independent of the
/// phases: in a long mix it comes while mixing, in a short one after.
///
/// Seeks follow what the listener hears: before the transition a seek is for
/// the outgoing track and the crossfade re-arms; after it, the seek is for the
/// incoming track and the outgoing one is dropped.
/// An armed or running crossfade in a `BufferPump`.
struct PumpOverlap {
    let incoming: PumpSource
    /// The armed overlap length in output frames.
    let lengthFrames: Int
    let onTransition: @Sendable () -> Void
    var phase: PumpOverlapPhase = .armed
    /// Sequence number of the buffer whose completion means the incoming
    /// track is heard. `nil` until the mix (or hand-over) starts.
    var transitionAfter: Int?
}

/// Where a `PumpOverlap` stands.
enum PumpOverlapPhase {
    /// Waiting for the boundary frame.
    case armed
    /// Past the boundary with too little of the outgoing track left to mix
    /// (a seek into the last second, or a late arm). The incoming track
    /// follows the outgoing one's end with no mix, gapless.
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

extension BufferPump {
    /// What `disarmOverlap` did.
    enum OverlapDisarm: Sendable, Equatable {
        /// The armed crossfade is gone and its source closed.
        case dropped
        /// Mixing has started: the crossfade completes and its transition fires.
        case tooLate
        case nothingArmed
    }

    /// The shortest mix the pump starts, in output frames.
    private var minimumMixFrames: Int {
        Int(CrossfadeMix.minimumOverlapSeconds * self.current.outputFormat.sampleRate)
    }

    // MARK: - Arming

    /// Arm a crossfade into `decoder`'s track, `lengthSeconds` long. Takes
    /// effect at the next loop iteration. Replaces a crossfade that is armed
    /// but not mixing yet.
    ///
    /// Returns `false` and arms nothing when the pump cannot take a crossfade:
    /// its feed has ended, it plays a CUE segment (the overlap start is
    /// measured from the file's end), or a crossfade is already mixing.
    func armOverlap(
        decoder: any Decoder,
        lengthSeconds: TimeInterval,
        onTransition: @Sendable @escaping () -> Void
    ) async throws -> Bool {
        guard !self.reachedEnd, self.current.maxFrames == nil else { return false }
        let replaced = self.overlap
        if let replaced {
            switch replaced.phase {
            case .armed, .armedLate:
                break

            case .mixing, .handedOver:
                return false
            }
        }
        let incoming = try PumpSource(decoder: decoder, outputFormat: self.current.outputFormat)
        let lengthFrames = Int((lengthSeconds * self.current.outputFormat.sampleRate).rounded())
        self.overlap = PumpOverlap(incoming: incoming, lengthFrames: lengthFrames, onTransition: onTransition)
        self.overlapHeard = false
        self.log.debug("pump.overlap.armed", ["id": self.id, "lengthFrames": lengthFrames])
        await replaced?.incoming.decoder.close()
        return true
    }

    /// Drop a crossfade that has not started mixing, and close its source.
    /// Once mixing has started it is too late: mixed buffers are already on
    /// the node, so the crossfade completes.
    func disarmOverlap() async -> OverlapDisarm {
        guard let overlap = self.overlap else { return .nothingArmed }
        switch overlap.phase {
        case .armed, .armedLate:
            self.overlap = nil
            self.log.debug("pump.overlap.disarmed", ["id": self.id])
            await overlap.incoming.decoder.close()
            return .dropped

        case .mixing, .handedOver:
            return .tooLate
        }
    }

    // MARK: - Feed loop

    /// One iteration of the feed loop while a crossfade is armed or running.
    /// Returns `false` when the loop should stop.
    func overlapStep() async throws -> Bool {
        guard let overlap = self.overlap else { return try await self.feedStep() }
        switch overlap.phase {
        case .armed:
            return try await self.armedStep(lengthFrames: overlap.lengthFrames)

        case .armedLate:
            return try await self.lateStep()

        case .mixing:
            return try await self.mixStep()

        case .handedOver:
            return try await self.feedStep()
        }
    }

    /// Before the boundary: schedule the outgoing track, cut so the last
    /// unmixed buffer ends exactly on the boundary frame, then start the mix.
    private func armedStep(lengthFrames: Int) async throws -> Bool {
        let remaining = Int(self.current.estimatedTotalOutputFrames - self.current.scheduledPosition)
        if remaining <= lengthFrames {
            if remaining >= self.minimumMixFrames {
                await self.startMix(length: remaining)
            } else {
                self.overlap?.phase = .armedLate
                self.log.debug("crossfade.mix.late", ["id": self.id, "remainingFrames": remaining])
            }
            return true
        }

        if let unmixed = self.current.pending.take(remaining - lengthFrames) {
            self.claimSlotAndSchedule(unmixed)
            return true
        }

        guard let buffer = self.current.makeReadBuffer(duration: Self.bufferDuration) else {
            self.log.error("buffer.alloc.failed", ["id": self.id])
            return false
        }
        if try await self.read(self.current, into: buffer) == 0 {
            // The outgoing track ended before the boundary: its duration
            // overstated its length by more than the whole overlap.
            self.log.debug("crossfade.mix.early_eof", ["id": self.id, "missingFrames": lengthFrames])
            await self.handOver()
            return true
        }
        if let converted = try self.resampledBuffer(buffer) {
            try self.queue(converted, on: self.current)
        }
        return true
    }

    /// Too late to mix: play the outgoing track to its end, then hand over.
    private func lateStep() async throws -> Bool {
        if let carried = self.current.pending.take(self.outputBufferFrames) {
            self.claimSlotAndSchedule(carried)
            return true
        }
        guard let buffer = self.current.makeReadBuffer(duration: Self.bufferDuration) else {
            self.log.error("buffer.alloc.failed", ["id": self.id])
            return false
        }
        if try await self.read(self.current, into: buffer) == 0 {
            await self.handOver()
            return true
        }
        if let converted = try self.resampledBuffer(buffer) {
            self.claimSlotAndSchedule(converted)
        }
        return true
    }

    /// Schedule one mixed buffer: up to one buffer's worth of frames from
    /// each track, through the equal-power curve.
    private func mixStep() async throws -> Bool {
        guard let armed = self.overlap, case let .mixing(plan) = armed.phase else { return true }
        let wanted = min(self.outputBufferFrames, plan.length - plan.mixed)
        _ = try await self.fill(armed.incoming, toAtLeast: wanted)
        let outgoingHasMore = try await plan.outgoingEnded ? false : self.fill(self.current, toAtLeast: wanted)

        // The reads above suspended: read the state again, a transition may
        // have been heard meanwhile.
        guard var overlap = self.overlap, case var .mixing(mix) = overlap.phase else { return true }
        mix.outgoingEnded = mix.outgoingEnded || !outgoingHasMore

        guard let incomingChunk = overlap.incoming.pending.take(wanted) else {
            // The incoming track ended inside the overlap: its duration
            // overstated its length by more than half.
            self.log.warning("crossfade.mix.incoming_eof", ["id": self.id, "mixedFrames": mix.mixed])
            overlap.phase = .mixing(mix)
            self.overlap = overlap
            await self.finishMix()
            return true
        }
        let frames = Int(incomingChunk.frameLength)
        let outgoingChunk = self.current.pending.take(frames)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: self.current.outputFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            self.log.error("buffer.alloc.failed", ["id": self.id])
            return false
        }
        do {
            try CrossfadeMix.mix(
                outgoing: outgoingChunk,
                incoming: incomingChunk,
                into: output,
                startFrame: mix.mixed,
                length: mix.length
            )
        } catch {
            self.log.error("crossfade.mix.failed", ["id": self.id, "error": String(reflecting: error)])
            self.reportFailure(error)
            throw error
        }
        mix.mixed += frames
        mix.outgoingSupplied += Int(outgoingChunk?.frameLength ?? 0)
        overlap.phase = .mixing(mix)
        self.overlap = overlap
        self.claimSlotAndSchedule(output)
        if mix.mixed >= mix.length {
            await self.finishMix()
        }
        return true
    }

    // MARK: - Phase changes

    private func startMix(length: Int) async {
        guard var overlap = self.overlap else { return }
        overlap.phase = .mixing(PumpOverlapMix(length: length))
        self.overlap = overlap
        self.log.debug("crossfade.mix.start", [
            "id": self.id, "lengthFrames": length, "armedFrames": overlap.lengthFrames,
        ])
        await self.markTransition()
    }

    /// The mix is complete: the incoming track becomes `current`. The
    /// outgoing source is closed if the transition is heard, else kept until
    /// it is.
    private func finishMix() async {
        guard let finished = self.overlap, case let .mixing(mix) = finished.phase else { return }
        let outgoing = self.current
        if mix.outgoingSupplied < mix.length {
            self.log.debug("crossfade.mix.early_eof", [
                "id": self.id, "missingFrames": mix.length - mix.outgoingSupplied,
            ])
        } else {
            let dropped = await self.dropTail(of: outgoing, ended: mix.outgoingEnded)
            if dropped > 0 {
                self.log.debug("crossfade.mix.truncated_tail", ["id": self.id, "droppedFrames": dropped])
            }
        }

        // dropTail suspended: read the state again.
        guard var overlap = self.overlap else { return }
        self.current = overlap.incoming
        self.log.debug("crossfade.mix.end", ["id": self.id, "mixedFrames": mix.mixed])
        if self.overlapHeard {
            self.overlap = nil
            await outgoing.decoder.close()
        } else {
            overlap.phase = .handedOver(outgoing: outgoing)
            self.overlap = overlap
        }
    }

    /// Hand over with no mix: the incoming track follows the outgoing one's
    /// last scheduled buffer, gapless.
    private func handOver() async {
        guard var overlap = self.overlap else { return }
        let outgoing = self.current
        self.current = overlap.incoming
        overlap.phase = .handedOver(outgoing: outgoing)
        self.overlap = overlap
        self.log.debug("crossfade.handover", ["id": self.id])
        await self.markTransition()
    }

    /// The incoming track is heard once every buffer queued before its first
    /// one is done. Fire at once when nothing is queued (the mix starts right
    /// after a seek, or the node ran dry).
    private func markTransition() async {
        if self.scheduledCount > self.lastCompletedSequence {
            self.overlap?.transitionAfter = self.scheduledCount
        } else {
            await self.fireTransition()
        }
    }

    /// The listener now hears the incoming track: tell the engine.
    func fireTransition() async {
        guard var overlap = self.overlap, !self.overlapHeard else { return }
        self.overlapHeard = true
        overlap.transitionAfter = nil
        self.log.debug("crossfade.heard", ["id": self.id])
        if case let .handedOver(outgoing) = overlap.phase {
            self.overlap = nil
            overlap.onTransition()
            await outgoing.decoder.close()
        } else {
            self.overlap = overlap
            overlap.onTransition()
        }
    }

    // MARK: - Seek and stop

    /// Decide which track a seek is for, before `reschedule` seeks `current`.
    /// Heard: the incoming one, and the outgoing source is closed. Not heard:
    /// the outgoing one, and the crossfade goes back to armed with the
    /// incoming source rewound, so the boundary is found again from the new
    /// position.
    func rewindOverlapForSeek() async throws {
        guard var overlap = self.overlap else { return }
        if self.overlapHeard {
            // Only a mix can still be running here: a heard hand-over has
            // already cleared the overlap.
            let outgoing = self.current
            self.current = overlap.incoming
            self.overlap = nil
            self.log.debug("crossfade.mix.end", ["id": self.id, "reason": "seek"])
            await outgoing.decoder.close()
            return
        }
        switch overlap.phase {
        case .armed, .armedLate:
            break

        case .mixing:
            try await overlap.incoming.seek(to: 0)

        case let .handedOver(outgoing):
            self.current = outgoing
            try await overlap.incoming.seek(to: 0)
        }
        overlap.phase = .armed
        overlap.transitionAfter = nil
        self.overlap = overlap
        self.log.debug("crossfade.rearmed", ["id": self.id])
    }

    /// End a crossfade because the pump stops. Close the source only this
    /// pump holds: the outgoing one once the transition is heard (the engine
    /// has moved to the incoming decoder), else the incoming one.
    func releaseOverlapOnStop() async {
        guard let overlap = self.overlap else { return }
        self.overlap = nil
        self.log.debug("crossfade.disarmed", ["id": self.id, "reason": "stop"])
        if self.overlapHeard {
            let outgoing = self.current
            self.current = overlap.incoming
            await outgoing.decoder.close()
        } else {
            if case let .handedOver(outgoing) = overlap.phase {
                self.current = outgoing
            }
            await overlap.incoming.decoder.close()
        }
    }

    // MARK: - Reading

    /// Read and convert from `source` until at least `frames` frames are
    /// pending. Returns `false` when the source reached its end first.
    private func fill(_ source: PumpSource, toAtLeast frames: Int) async throws -> Bool {
        while source.pending.count < frames {
            guard let buffer = source.makeReadBuffer(duration: Self.bufferDuration) else {
                self.log.error("buffer.alloc.failed", ["id": self.id])
                return false
            }
            if try await self.read(source, into: buffer) == 0 {
                return false
            }
            if let converted = try self.resampledBuffer(buffer, from: source) {
                try self.queue(converted, on: source)
            }
        }
        return true
    }

    /// Add converted frames to `source`'s pending queue, reporting a failure
    /// to the engine like a read failure.
    private func queue(_ converted: AVAudioPCMBuffer, on source: PumpSource) throws {
        do {
            try source.pending.append(converted)
        } catch {
            self.log.error("crossfade.mix.failed", ["id": self.id, "error": String(reflecting: error)])
            self.reportFailure(error)
            throw error
        }
    }

    /// Output frames the outgoing track still had when the mix ended, which
    /// are dropped: the pending ones, plus one probe read when its decoder has
    /// not reported its end. A container that understates its duration can
    /// hold more than the probe finds, so this is a lower bound, and it is
    /// only logged.
    private func dropTail(of outgoing: PumpSource, ended: Bool) async -> Int {
        var dropped = outgoing.pending.count
        outgoing.pending.removeAll()
        guard !ended, let probe = outgoing.makeReadBuffer(duration: Self.bufferDuration) else {
            return dropped
        }
        do {
            let frames = try await outgoing.read(into: probe)
            let ratio = outgoing.outputFormat.sampleRate / outgoing.decoder.sourceFormat.sampleRate
            dropped += Int((Double(frames) * ratio).rounded())
        } catch {
            // The tail is being dropped anyway; a failed probe only makes the
            // logged count smaller.
            self.log.debug("crossfade.mix.tail_probe.failed", ["id": self.id, "error": String(reflecting: error)])
        }
        return dropped
    }
}
