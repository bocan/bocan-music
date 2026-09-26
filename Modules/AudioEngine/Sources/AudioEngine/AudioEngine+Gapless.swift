import Foundation

// MARK: - AudioEngine + Gapless (track-end handling and gapless transitions)

extension AudioEngine {
    // MARK: - Internal

    func handleEnded(firedBy pumpID: String) {
        let currentID = self.pump?.id ?? "nil"
        let pendingID = self.pendingNextPump?.id ?? "nil"
        // Ignore EOF signals from pumps that are neither the active nor the
        // pending-next pump.  Stale signals arise after a seek (which replaces
        // the pump) or after the user triggers a rapid load/skip.
        guard pumpID == currentID || pumpID == pendingID else {
            self.log.debug("engine.handleEnded.stale", [
                "firedBy": pumpID, "current": currentID, "pending": pendingID,
            ])
            return
        }
        self.log.debug("engine.handleEnded.entry", [
            "firedBy": pumpID, "current": currentID, "pending": pendingID,
        ])
        if let next = pendingNextPump, next !== pump {
            self.performGaplessTransition(to: next)
        } else {
            self.finalizeTrackEnded(firedBy: currentID)
        }
    }

    func performGaplessTransition(to next: BufferPump) {
        // At this moment the outgoing pump has scheduled its complete tail on
        // the player node (that's what its EOF means); ~4 buffers are still
        // in flight and will play out over ~800 ms.  Start the incoming pump
        // NOW — its scheduleBuffer calls land strictly after the outgoing
        // buffers in the node's queue, which is what makes the transition
        // gapless without audio interleaving.
        let prevPump = self.pump
        self.pump = next
        self.pendingNextPump = nil
        self._currentTime = 0
        // Capture the cumulative sample position so currentTime restarts from 0
        // for the new track without stopping the player node.
        let playerNode = self.graph.playerNode
        if let renderTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: renderTime) {
            self._playerTimeOffset = playerTime.sampleTime
        } else {
            self._playerTimeOffset = 0
        }
        self._duration = self.pendingNextDuration
        // The pending decoder becomes the active decoder.
        self.decoder = self.pendingNextDecoder
        self.pendingNextDecoder = nil
        self.currentReplayGain = self.pendingNextReplayGain
        self.pendingNextReplayGain = nil

        let transition = self.pendingNextTransition
        self.pendingNextTransition = nil

        // Force re-emit .playing for the new track's timeline.
        self.lastState = nil
        self.emit(.playing)
        transition?()

        // Start the deferred pump task; its buffers queue after the outgoing pump's tail.
        let newPumpID = next.id
        // [weak self] on the stored onEnded closure: the swapped-in pump retains
        // it, so a strong capture re-forms the same engine ⇄ pump cycle that
        // play() avoids. (Kept on the inner closure, not the transient outer
        // Task, so Swift 6 doesn't flag capturing an enclosing weak binding.)
        Task {
            await next.start { [weak self] in
                Task { await self?.handleEnded(firedBy: newPumpID) }
            } onError: { [weak self] error in
                Task { await self?.handlePumpError(error, firedBy: newPumpID) }
            }
        }

        // Stop (clean up) the old pump; it has already finished scheduling.
        let oldPump = prevPump
        Task { await oldPump?.stop() }

        self.lastGaplessTransitionAt = Date()
        self.log.debug("engine.gapless.transition", [
            "old": prevPump?.id ?? "nil", "new": next.id,
        ])
    }

    func finalizeTrackEnded(firedBy currentID: String) {
        // Suppress a spurious second `.ended` arriving within the gapless
        // settle window: the just-activated pump can report EOF before its
        // first buffer has rendered, which would tear down the player node
        // and silently stop playback of a track that just started.
        if let t = self.lastGaplessTransitionAt, Date().timeIntervalSince(t) < 1.5 {
            self.log.debug("engine.ended.spurious.afterGapless.ignored", [
                "firedBy": currentID,
            ])
            return
        }
        // No gapless next, or degenerate case (new pump finished before old).
        // Clean up any stale pending state.
        let staleNext = self.pendingNextPump
        let staleDecoder = self.pendingNextDecoder
        // A crossfade armed after the feed had already ended never started.
        let staleCrossfadeDecoder = self.pendingCrossfade?.decoder
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        self.pendingNextReplayGain = nil
        self.pendingCrossfade = nil
        Task {
            await staleNext?.stop()
            await staleDecoder?.close()
            await staleCrossfadeDecoder?.close()
        }

        self.graph.playerNode.stop()
        self.emit(.ended)
        self.log.debug("engine.playback.ended")
    }
}

// MARK: - AudioEngine + Crossfade transition (ADR-095)

/// The next track of an armed crossfade. The engine holds it from arming
/// until the pump reports the incoming track heard; the pump reads it in the
/// meantime. Local files only, never a CUE segment.
struct PendingCrossfade {
    /// Tells this crossfade's transition apart from a stale one still on its
    /// way from an earlier arm.
    let token: UUID
    let decoder: any Decoder
    let duration: TimeInterval
    /// Becomes the engine's `currentReplayGain` at the transition.
    let replayGain: TrackReplayGain?
    let transition: @Sendable () -> Void
}

extension AudioEngine {
    /// The pump reports that the listener hears the incoming track. Ignored
    /// when it belongs to an arm or a pump that has since been replaced.
    func handleCrossfadeTransition(token: UUID, firedBy pumpID: String) {
        guard self.pendingCrossfade?.token == token, pumpID == self.pump?.id else {
            self.log.debug("crossfade.transition.stale", ["firedBy": pumpID, "current": self.pump?.id ?? "nil"])
            return
        }
        self.completeCrossfadeTransition()
    }

    /// Make the incoming track the engine's track, at the moment its first
    /// mixed frame is heard. What `performGaplessTransition` does, minus the
    /// pump swap: the one pump already reads the incoming track, and it
    /// closes the outgoing decoder itself once it lets go of it.
    func completeCrossfadeTransition() {
        guard let pending = self.pendingCrossfade else { return }
        self.pendingCrossfade = nil
        self.decoder = pending.decoder
        self.currentReplayGain = pending.replayGain
        self._duration = pending.duration
        self._currentTime = 0
        // Rebaseline so currentTime counts the incoming track from 0 without
        // stopping the node, as the gapless transition does.
        let playerNode = self.graph.playerNode
        if let renderTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: renderTime) {
            self._playerTimeOffset = playerTime.sampleTime
        } else {
            self._playerTimeOffset = 0
        }
        // Force re-emit .playing for the new track's timeline. Paused (a seek
        // or a device change settled the transition) stays paused.
        if self._state == .playing {
            self.lastState = nil
            self.emit(.playing)
        }
        self.log.debug("crossfade.transition", ["pump": self.pump?.id ?? "nil"])
        pending.transition()
    }

    /// After the pump stopped: complete a crossfade whose incoming track was
    /// heard (the listener is on it now), drop one that was not.
    func settleCrossfade(heard: Bool, reason: String) async {
        if heard, self.pendingCrossfade != nil {
            self.completeCrossfadeTransition()
        } else {
            await self.dropPendingCrossfade(reason: reason)
        }
    }

    /// Forget an armed crossfade and close its decoder. For teardown paths
    /// that have already stopped the pump.
    func dropPendingCrossfade(reason: String) async {
        guard let pending = self.pendingCrossfade else { return }
        self.pendingCrossfade = nil
        self.log.debug("crossfade.disarmed", ["reason": reason])
        await pending.decoder.close()
    }
}
