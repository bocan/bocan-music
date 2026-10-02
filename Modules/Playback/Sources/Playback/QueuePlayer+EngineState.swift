import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Engine state

extension QueuePlayer {
    // MARK: Engine state subscription

    func subscribeToEngineState() async {
        for await engineState in self.engine.state {
            switch engineState {
            case .ended:
                self.stopScrobbleUpdateLoop()
                await self.handleTrackEnded()

            case .playing:
                self.lastEmittedState = .playing
                self.stateContinuation?.yield(.playing)
                await self.gaplessScheduler.start()
                self.startScrobbleUpdateLoop()

            case .paused:
                self.lastEmittedState = .paused
                self.stateContinuation?.yield(.paused)
                self.stopScrobbleUpdateLoop()

            default:
                self.lastEmittedState = engineState
                self.stateContinuation?.yield(engineState)
            }
        }
    }

    private func startScrobbleUpdateLoop() {
        self.scrobbleUpdateTask?.cancel()
        self.scrobbleUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                let elapsed = await self.engine.currentTime
                await self.historyRecorder.update(elapsed: elapsed)
                // Reuse this 5 s tick for podcast position write-back; do not
                // add a second timer (writing on every sub-second engine
                // callback would be position spam).
                await self.persistPodcastPositionIfNeeded()
            }
        }
    }

    private func stopScrobbleUpdateLoop() {
        self.scrobbleUpdateTask?.cancel()
        self.scrobbleUpdateTask = nil
    }

    /// Writes the current engine position back through the podcast resolver
    /// when the current item is a `.podcast`. A no-op for every other source.
    ///
    /// Invoked from the 5 s history tick and from `pause()` / `stop()` /
    /// `savePositionForSuspend()` so a resume point survives between ticks.
    /// Visible to tests, which drive it directly rather than waiting on the timer.
    func persistPodcastPositionIfNeeded() async {
        guard let resolver = self.podcastResolver,
              let item = await self.queue.currentItem,
              case let .podcast(feedURL, guid) = item.playableSource else { return }
        let position = await self.engine.currentTime
        let duration = await self.engine.duration
        await resolver.persistPosition(
            feedURL: feedURL,
            episodeGUID: guid,
            position: position,
            duration: duration
        )
    }

    /// Applies the per-episode podcast resume for `item`, returning the position
    /// it sought to, or `nil` when the item is not a podcast, has no resolver,
    /// or the saved position is <= 1 second (so a seek would be pointless).
    ///
    /// Called from `loadAndPlay` after the engine has loaded the item and before
    /// playback starts. Visible to tests, which drive it directly to assert the
    /// resolver is consulted and the seek gate is honoured.
    @discardableResult
    func applyPodcastResumeIfNeeded(for item: QueueItem) async -> TimeInterval? {
        guard case let .podcast(feedURL, guid) = item.playableSource,
              let resolver = self.podcastResolver else { return nil }
        let resume = await resolver.resumePosition(feedURL: feedURL, episodeGUID: guid)
        guard resume > 1 else { return nil }
        do {
            try await self.engine.seek(to: resume)
            self.log.debug("queueplayer.podcast.resume", ["position": resume])
        } catch {
            self.log.warning(
                "queueplayer.podcast.resume.seekFailed",
                ["position": resume, "error": String(reflecting: error)]
            )
        }
        return resume
    }

    /// Marks `item` played through the podcast resolver when it is a `.podcast`.
    /// A no-op for every other source (and for `nil`). Idempotent, so calling it
    /// from both the natural-end and gapless-handoff paths is harmless.
    func markPlayedIfPodcast(_ item: QueueItem?) async {
        guard let resolver = self.podcastResolver,
              let item,
              case let .podcast(feedURL, guid) = item.playableSource else { return }
        await resolver.markPlayed(feedURL: feedURL, episodeGUID: guid)
        self.log.debug("queueplayer.podcast.markPlayed", ["guid": guid])
    }

    /// Visible to tests so they can drive the end-of-track flow without needing a
    /// real decoded audio file. Production callers always go through
    /// `subscribeToEngineState()`.
    func handleTrackEnded() async {
        // A play(…) call is in the middle of replacing the queue — it will load and
        // start the new track itself.  Advancing here would corrupt the new queue.
        guard self.activeReplaceCount == 0 else {
            self.log.debug("queueplayer.ended.deferredToPlay", [:])
            return
        }
        let elapsed = await engine.duration // track played fully
        await self.historyRecorder.trackDidEnd(elapsed: elapsed)

        // If a gapless transition fired recently the new pump can report a
        // spurious EOF before its first buffer renders; swallow that event so
        // we don't double-advance.  The settle window is 3 s — well above the
        // ~800 ms buffer-drain window used by the engine.
        if let t = self.lastGaplessTransitionAt,
           Date().timeIntervalSince(t) < Self.gaplessSettleWindow {
            self.lastGaplessTransitionAt = nil
            self.log.debug("queueplayer.ended.swallowed.afterGapless", ["age": Date().timeIntervalSince(t)])
            return
        }

        // Mark a finished podcast episode played. The current item is still the
        // one that just ended (advance happens below). Placed after the gapless
        // swallow so a spurious post-handoff `.ended` does not mark the freshly
        // started item. Idempotent with the near-end position write in 21-4.
        await self.markPlayedIfPodcast(self.queue.currentItem)

        // Stop-after-current wins over repeat modes. Reset the flag then stop.
        if await self.queue.stopAfterCurrent {
            await self.queue.setStopAfterCurrent(false)
            self.stateContinuation?.yield(.ended)
            await self.nowPlayingCentre?.setPlaying(false)
            await self.nowPlayingCentre?.clear()
            return
        }

        guard let next = await queue.advance() else {
            self.stateContinuation?.yield(.ended)
            await self.nowPlayingCentre?.setPlaying(false)
            await self.nowPlayingCentre?.clear()
            return
        }

        // Normal (non-gapless) load for next item.
        self.stateContinuation?.yield(.loading)
        do {
            try await self.loadAndPlay(item: next)
        } catch {
            await self.skipMissingFileAndContinue(failedItem: next, error: error)
        }
    }

    /// Returns `true` when `error` indicates the track's file is missing or
    /// its bookmark can no longer be resolved — cases where skipping and
    /// disabling the track is the right recovery rather than surfacing a failure.
    private static func isMissingFileError(_ error: Error) -> Bool {
        if case AudioEngineError.fileNotFound = error {
            return true
        }
        if case PlaybackError.bookmarkResolutionFailed = error {
            return true
        }
        return false
    }

    /// Called when `handleTrackEnded` fails to load the next track.
    ///
    /// If the error is a missing-file / unresolvable-bookmark error, the failed
    /// track is disabled in the database, removed from the queue, and the next
    /// item is attempted. The loop repeats until a loadable track is found, the
    /// queue is exhausted, or a safety cap of 50 consecutive failures is reached
    /// (guards against a library where every file has been deleted).
    ///
    /// Non-missing-file errors fall through immediately as a `.failed` state.
    private func skipMissingFileAndContinue(failedItem: QueueItem, error: Error) async {
        var item = failedItem
        var loadError = error
        let maxSkips = 50

        for skipped in 1 ... maxSkips {
            guard Self.isMissingFileError(loadError) else {
                self.log.error("queueplayer.advance.failed", ["error": String(reflecting: loadError)])
                self.stateContinuation?.yield(.failed(
                    AudioEngineError.decoderFailure(codec: "unknown", underlying: loadError)
                ))
                return
            }

            self.log.warning("queueplayer.skip.missing", [
                "trackID": item.trackID, "url": item.fileURL, "skip": skipped,
            ])

            // Peek ahead while the queue still contains the failed item, so
            // currentIndex lines up with the item we're about to remove.
            let next = await self.queue.peekNextIgnoringRepeatOne()

            // Disable in DB — best effort; a write failure must not stop us,
            // but it does leave the missing track in the library (#494).
            do {
                try await self.trackRepo.disable(id: item.trackID)
            } catch {
                self.log.warning("queueplayer.skip.disableFailed", [
                    "trackID": item.trackID,
                    "error": String(reflecting: error),
                ])
            }

            // Remove from queue. PlaybackQueue.remove advances currentIndex to
            // what was physically next, matching what peekNextIgnoringRepeatOne
            // returned above.
            await self.queue.remove(ids: [item.id])

            guard let next else {
                self.stateContinuation?.yield(.ended)
                await self.nowPlayingCentre?.setPlaying(false)
                await self.nowPlayingCentre?.clear()
                return
            }

            // Mirror what next() does before loadAndPlay to keep gapless state clean.
            await self.gaplessScheduler.reset()

            self.stateContinuation?.yield(.loading)
            do {
                try await self.loadAndPlay(item: next)
                return
            } catch {
                item = next
                loadError = error
            }
        }

        // Safety cap reached.
        self.log.error("queueplayer.skip.exhausted", ["skipped": maxSkips])
        self.stateContinuation?.yield(.failed(
            AudioEngineError.decoderFailure(codec: "unknown", underlying: loadError)
        ))
    }
}
