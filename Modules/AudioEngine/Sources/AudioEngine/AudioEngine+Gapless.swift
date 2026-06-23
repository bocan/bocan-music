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
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        Task {
            await staleNext?.stop()
            await staleDecoder?.close()
        }

        self.graph.playerNode.stop()
        self.emit(.ended)
        self.log.debug("engine.playback.ended")
    }
}
