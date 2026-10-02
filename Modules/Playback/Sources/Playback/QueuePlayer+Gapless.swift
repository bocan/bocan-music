import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Gapless and crossfade boundaries

extension QueuePlayer {
    // MARK: Gapless next URL resolution

    /// The next item and how to arm its boundary, or `nil` when nothing is
    /// armed (ADR-095, "Which boundaries crossfade"): no next item or
    /// stop-after-current; else a crossfade when the crossfade scheduler
    /// allows one; else the plain gapless rules. Visible to tests.
    func resolveNextBoundary() async -> (item: QueueItem, transition: BoundaryTransition)? {
        guard await !self.queue.stopAfterCurrent else { return nil }
        guard let item = await queue.peekNext() else { return nil }
        let currentItem = await queue.currentItem

        // A crossfade needs neither the format gate nor the cross-album
        // toggle below: both exist only for raw gapless.
        if let seconds = await self.crossfadeScheduler.crossfadeSeconds(from: currentItem, to: item) {
            return (item: item, transition: .crossfade(seconds: seconds))
        }

        // Determine whether the next item's album has `force_gapless` set and
        // the current item belongs to the same album.
        var forceGapless = false
        let sameAlbum: Bool = {
            guard let nextID = item.albumID, let curID = currentItem?.albumID else { return false }
            return nextID == curID
        }()

        if sameAlbum, let nextAlbumID = item.albumID {
            do {
                forceGapless = try await self.albumRepo.fetch(id: nextAlbumID).forceGapless
            } catch {
                // The album's own "force gapless" flag is ignored, so an
                // album meant to play gapless may gap (#494).
                self.log.warning("queueplayer.gapless.albumLookupFailed", [
                    "album": nextAlbumID,
                    "error": String(reflecting: error),
                ])
            }
        } else if !sameAlbum {
            // Cross-album boundary.  Honour the user-controlled
            // `playback.crossAlbumGapless` toggle: when enabled, attempt
            // gapless across albums by relaxing the padding-tag check (still
            // bounded by the hardware sample-rate / channel-count gate inside
            // `GaplessScheduler.checkAndArm`).  When disabled (default),
            // refuse arming so the engine does a normal stop/load/play.
            let allowCrossAlbum = UserDefaults.standard.bool(forKey: "playback.crossAlbumGapless")
            guard allowCrossAlbum else { return nil }
            forceGapless = true
        }

        return (item: item, transition: .gapless(forceGapless: forceGapless))
    }

    /// Resolve the next item's URL into a security-scoped URL, arm the
    /// boundary in the engine (`armNext`), and release the scope once the
    /// decoder has opened the file.  Mirrors the scope-handling pattern in
    /// `loadAndPlay`.
    ///
    /// Without this, gapless prefetch fails outside the sandbox with
    /// "Access denied" because the raw `file://` URL has no permission grant.
    func performGaplessPrefetch(item: QueueItem, transition: BoundaryTransition) async throws {
        var resolved = try await self.resolvePrefetchURL(for: item)
        let url = resolved.url

        // Fail early if the file is unreachable — avoids opaque AVAudioFile errors.
        guard FileManager.default.fileExists(atPath: url.path) else {
            if resolved.resolvedFromPerFileBookmark {
                url.stopAccessingSecurityScopedResource()
            }
            // `rootScope` deinit releases on return.
            throw PlaybackError.bookmarkResolutionFailed(
                trackID: item.trackID,
                underlying: URLError(.fileDoesNotExist)
            )
        }

        do {
            try await self.armNext(url: url, item: item, transition: transition)
        } catch {
            if resolved.resolvedFromPerFileBookmark {
                url.stopAccessingSecurityScopedResource()
            }
            // `rootScope` deinit releases on return.
            throw error
        }

        // The decoder has opened the file; release scope.
        if resolved.resolvedFromPerFileBookmark {
            url.stopAccessingSecurityScopedResource()
        }
        // Drop the RAII handle so the root scope is released here rather than
        // waiting for the function to return (matches the pre-RAII timing).
        withExtendedLifetime(resolved.rootScope) {}
        resolved.rootScope = nil
    }

    /// Opens `url` as the next track in the engine: a crossfade or a plain
    /// gapless boundary, as `transition` says. The engine falls back to
    /// gapless itself when a crossfade cannot be armed (a boundary too short
    /// for its decoders' durations, or the pump refused), and says how it
    /// prepared the boundary; `handleGaplessTransition` reads that back.
    private func armNext(url: URL, item: QueueItem, transition: BoundaryTransition) async throws {
        let onTransitionCallback = self.onGaplessTransitionCaptured
        let onTransition: @Sendable () -> Void = {
            Task { @Sendable in
                await onTransitionCallback?(item)
            }
        }
        let replayGain = await self.replayGain(for: item, track: nil)
        self.armedBoundary = nil
        let preparation: NextTrackPreparation
        switch transition {
        case let .crossfade(seconds):
            preparation = try await self.engine.enableCrossfadeNext(
                url: url,
                overlapSeconds: seconds,
                replayGain: replayGain,
                onTransition: onTransition
            )
            self.log.debug("crossfade.decision", [
                "decision": preparation == .crossfade ? "crossfade" : "gapless",
                "reason": preparation == .crossfade ? "boundary" : "engineFallback",
                "next": item.trackID,
            ])

        case .gapless:
            if await self.crossfadeScheduler.isEnabled {
                self.log.debug("crossfade.decision", [
                    "decision": "gapless",
                    "reason": "boundary",
                    "next": item.trackID,
                ])
            }
            preparation = try await self.engine.enableGaplessNext(
                url: url, replayGain: replayGain, onTransition: onTransition
            )
        }
        self.armedBoundary = (itemID: item.id, preparation: preparation)
    }

    /// The ReplayGain facts for `item`, from its track row as it is now, so a
    /// track analysed after it was queued plays at its new level (#573).
    /// `track` is that row when the caller has already read it. Visible to
    /// tests.
    func replayGain(for item: QueueItem, track: Track?) async -> TrackReplayGain? {
        guard !item.playableSource.isRemote else { return nil }
        var row = track
        if row == nil {
            do {
                row = try await self.trackRepo.fetch(id: item.trackID)
            } catch {
                // The track plays at its own level, not the levelled one.
                self.log.warning("queueplayer.replayGain.trackLookupFailed", [
                    "trackID": item.trackID,
                    "error": String(reflecting: error),
                ])
            }
        }
        return await QueueReplayGain.facts(for: item, track: row, playOrder: self.queue.items)
    }

    /// Captured reference to the transition handler so `armNext` can invoke
    /// it from a `@Sendable` closure without re-capturing `self`. This
    /// closure, handed to the engine with the next track, is the only path a
    /// transition takes to `handleGaplessTransition` (#575).
    private var onGaplessTransitionCaptured: (@Sendable (QueueItem) async -> Void)? {
        { [weak self] item in await self?.handleGaplessTransition(to: item) }
    }

    private func handleGaplessTransition(to item: QueueItem) async {
        // A play(…) call is replacing the queue — ignore the stale gapless event.
        guard self.activeReplaceCount == 0 else {
            self.log.debug("queueplayer.gapless.deferredToPlay", [:])
            return
        }
        // The engine has seamlessly transitioned to `item`. Capture the
        // outgoing item before advancing so a finished podcast episode can be
        // marked played on the handoff (not only on `handleTrackEnded`).
        let outgoing = await self.queue.currentItem
        _ = await self.queue.advance()
        // A crossfade or hand-over in the playing pump swaps no pump, so no
        // spurious end follows it and the settle window stays off (see
        // `armedBoundary`). Only a separate pump needs the window.
        let preparation = self.armedBoundary?.itemID == item.id ? self.armedBoundary?.preparation : nil
        self.armedBoundary = nil
        self.lastGaplessTransitionAt = preparation?.firesWhenHeard == true ? nil : Date()

        // Credit the outgoing play before we overwrite recorder state.
        // The handoff only fires when the previous track reached its natural end,
        // so it counts as a full play for scrobble purposes.
        await self.historyRecorder.trackDidEndNaturally()
        await self.markPlayedIfPodcast(outgoing)

        // Update metadata for the new track.
        if case .podcast = item.playableSource {
            let capturedEngine = self.engine
            await self.nowPlayingCentre?.updatePodcast(
                title: item.title ?? "",
                showName: item.artistName ?? "",
                duration: item.duration
            ) { await capturedEngine.currentTime }
        } else if let track = await self.nowPlayingTrack(item.trackID) {
            self.emitCurrentTrack(track)
            let capturedEngine = self.engine
            let coverPath = await self.resolveCoverArtPath(for: track)
            await self.nowPlayingCentre?.update(
                track: track,
                duration: item.duration,
                coverArtPath: coverPath
            ) { await capturedEngine.currentTime }
        }

        await self.notifyHistoryStart(for: item)

        self.log.debug("queueplayer.gapless.transition", [
            "trackID": item.trackID,
            "preparation": preparation.map { String(describing: $0) } ?? "unknown",
        ])
    }
}
