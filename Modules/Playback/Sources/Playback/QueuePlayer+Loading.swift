import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Load and play

extension QueuePlayer {
    // MARK: Load + play

    func loadCurrentItem() async throws {
        guard let item = await queue.currentItem else { return }
        try await self.loadAndPlay(item: item, autoPlay: false)
    }

    func loadAndPlay(item: QueueItem, autoPlay: Bool = true) async throws {
        // A manual load always starts fresh; the engine's load drops any
        // armed crossfade.
        self.armedBoundary = nil

        // A non-gapless load means the settle window no longer applies;
        // clear it so a natural end-of-track is never accidentally swallowed.
        // (Handles manual skips, repeat-one replays, and the normal-fallback
        // path when gapless prefetch failed.)
        self.lastGaplessTransitionAt = nil

        // Resolve a playable URL (priority order in `resolvePlayableURL`).
        var resolved = try await self.resolvePlayableURL(for: item)
        let url = resolved.url

        // Fetch track metadata (for NowPlaying).
        let track = await self.nowPlayingTrack(item.trackID)
        self.emitCurrentTrack(track)

        await self.loadMarkers(for: item)

        try await self.engine.load(url, replayGain: self.replayGain(for: item, track: track))
        // Release whichever scope was started — AVAudioFile already holds an open
        // file descriptor so the scope is no longer needed.
        if resolved.resolvedFromPerFileBookmark {
            url.stopAccessingSecurityScopedResource()
        }
        // Drop the RAII handle so the root scope is released here rather than
        // waiting for the function to return (matches the pre-RAII timing).
        withExtendedLifetime(resolved.rootScope) {}
        resolved.rootScope = nil

        // Per-episode podcast resume: seek to the saved position for this
        // episode before playback begins. This is authoritative for a podcast
        // item; the global last-position restore path skips podcast items so
        // the two resume mechanisms never fight.
        await self.applyPodcastResumeIfNeeded(for: item)

        await self.updateNowPlaying(for: item, track: track)

        await self.notifyHistoryStart(for: item)

        if autoPlay {
            try await self.engine.play()
            await self.nowPlayingCentre?.setPlaying(true)
        }

        self.log.debug("queueplayer.loaded", ["trackID": item.trackID])

        await self.precacheNextSubsonicItem()
    }

    /// ADR-087: load the track's CUE markers. Fewer than two is inert
    /// (nothing to navigate, nothing to draw), normalised to empty here so
    /// every consumer shares one rule. Emitted on every load so the strip
    /// clears the previous track's ticks.
    private func loadMarkers(for item: QueueItem) async {
        let fetched: [TrackMarker]
        do {
            fetched = try await self.markerRepo.markers(forTrack: item.trackID)
        } catch {
            // The scrubber loses its chapter ticks, which reads as a track
            // that simply has none (#494).
            self.log.warning("queueplayer.markers.readFailed", [
                "trackID": item.trackID,
                "error": String(reflecting: error),
            ])
            fetched = []
        }
        self.currentMarkers = fetched.count >= 2 ? fetched : []
        self.markerContinuation?.yield(self.currentMarkers)
    }

    /// Points Now Playing at the item that has just loaded: podcast mode,
    /// stream mode for radio, or the track row with its cover art.
    private func updateNowPlaying(for item: QueueItem, track: Track?) async {
        if case .podcast = item.playableSource {
            // A podcast has no local `tracks` row; drive Now Playing from the
            // QueueItem snapshot (episode title, show name) in podcast mode.
            let capturedEngine = self.engine
            await self.nowPlayingCentre?.updatePodcast(
                title: item.title ?? "",
                showName: item.artistName ?? "",
                duration: item.duration
            ) { await capturedEngine.currentTime }
        } else if case .internetRadio = item.playableSource {
            // Radio: no tracks row either. Seed with the station snapshot;
            // live ICY titles overwrite the title slot as they arrive (27-5).
            let capturedEngine = self.engine
            await self.nowPlayingCentre?.updateStream(
                title: item.title ?? "",
                stationName: item.artistName ?? ""
            ) { await capturedEngine.currentTime }
        } else if let track {
            let capturedEngine = self.engine
            let coverPath = await self.resolveCoverArtPath(for: track)
            await self.nowPlayingCentre?.update(
                track: track,
                duration: item.duration,
                coverArtPath: coverPath
            ) { await capturedEngine.currentTime }
        }
    }

    /// Fire-and-forget pre-cache of the next item if it's a Subsonic source.
    /// The resolver itself checks the server's `precacheNext` flag.
    private func precacheNextSubsonicItem() async {
        if let resolver = self.subsonicResolver,
           let next = await self.queue.peekNextIgnoringRepeatOne(),
           case let .subsonic(nextServerID, nextSongID) = next.playableSource {
            Task.detached(priority: .utility) {
                await resolver.precache(serverID: nextServerID, songID: nextSongID)
            }
        }
    }

    /// Resolves the on-disk cover-art path for a track, preferring the
    /// track's own embedded art (unique per-track art, e.g. a single with
    /// distinct artwork) and falling back to the album's cached path.
    /// Returns `nil` when no art is available; `NowPlayingCentre` then
    /// shows the system's generic audio glyph.
    func resolveCoverArtPath(for track: Track) async -> String? {
        if let hash = track.coverArtHash {
            do {
                if let art = try await self.coverArtRepo.fetch(hash: hash) {
                    return art.path
                }
            } catch {
                self.log.warning("queueplayer.cover_art.fetch_failed", [
                    "error": String(reflecting: error),
                ])
            }
        }
        if let albumID = track.albumID {
            do {
                return try await self.albumRepo.fetch(id: albumID).coverArtPath
            } catch {
                self.log.warning("queueplayer.album.fetch_failed", [
                    "albumID": albumID,
                    "error": String(reflecting: error),
                ])
            }
        }
        return nil
    }

    /// Dispatches start-of-track notifications to the history recorder using
    /// the Subsonic-specific overload when the item streams from a remote
    /// server. Subsonic items don't have a row in the local `tracks` table,
    /// so the recorder must skip its usual local-DB writes.
    func notifyHistoryStart(for item: QueueItem) async {
        // Internet radio is a live stream — no track row, no scrobble.
        // Skip the history recorder entirely.
        if case .internetRadio = item.playableSource {
            return
        }
        // Podcasts are not music tracks and never scrobble to Last.fm /
        // ListenBrainz. Skip the recorder so no scrobble is ever enqueued.
        if case .podcast = item.playableSource {
            return
        }
        if let context = Self.subsonicPlayContext(for: item) {
            await self.historyRecorder.trackDidStart(subsonic: context)
        } else {
            await self.historyRecorder.trackDidStart(trackID: item.trackID, duration: item.duration)
        }
    }

    /// The scrobble payload for a Subsonic queue item, or nil for any other
    /// source. Carries the album so Last.fm / ListenBrainz receive it (#408).
    /// The album artist stays nil: the Subsonic `Child` a queue item is built
    /// from has no album-artist field, and guessing the track artist would be
    /// wrong for compilations.
    static func subsonicPlayContext(for item: QueueItem) -> SubsonicPlayContext? {
        guard case let .subsonic(serverID, songID) = item.playableSource else { return nil }
        return SubsonicPlayContext(
            serverID: serverID,
            songID: songID,
            title: item.title ?? "",
            artist: item.artistName ?? "",
            albumArtist: nil,
            album: item.albumName,
            duration: item.duration
        )
    }

    /// The track row behind the now-playing metadata, or nil with a log line:
    /// a failed read otherwise leaves the strip, the lock screen and the menu
    /// bar showing nothing, as though no track were loaded (#494).
    func nowPlayingTrack(_ trackID: Int64) async -> Track? {
        do {
            return try await self.trackRepo.fetch(id: trackID)
        } catch {
            self.log.warning("queueplayer.nowPlaying.trackLookupFailed", [
                "trackID": trackID,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }
}
