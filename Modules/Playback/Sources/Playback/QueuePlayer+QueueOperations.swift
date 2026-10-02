import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Queue operations

/// The queue commands: replace and play, append, skip, and the queue's modes.
public extension QueuePlayer {
    // MARK: - Queue operations

    /// Replace the queue with `trackIDs` and begin playing at `index`.
    func play(trackIDs: [Int64], startingAt index: Int = 0) async throws {
        let items = try await buildItems(for: trackIDs)
        // Increment before the first queue mutation so handleTrackEnded /
        // handleGaplessTransition defer to this call during suspension points.
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        await self.queue.replace(with: items, startAt: index)
        // Load then play directly — do NOT call self.play() here because that method
        // contains an extra loadCurrentItem() guard for the "press Play on idle engine"
        // path, which would cause a redundant double-load of the same URL.
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Replace the queue with pre-built `items` and begin playing at `index`.
    ///
    /// Prefer this over `play(trackIDs:)` when the caller already has the `Track`
    /// objects in memory (e.g. the current browse view).  Avoids the per-track DB
    /// round-trips inside `buildItems(for:)`, which become the dominant latency
    /// when queueing a large library (~32 queries/track, seconds for 10k+ tracks).
    ///
    /// Pass `shuffle: true` to pre-shuffle the items with a fresh seed before
    /// loading them into the queue.  This ensures the **first** track played is
    /// already a randomly-selected one — not the original `items[0]`.  The queue
    /// shuffle flag is also set so that auto-advance continues in shuffle order.
    func play(items: [QueueItem], startingAt index: Int = 0, shuffle: Bool = false) async throws {
        guard !items.isEmpty else { throw PlaybackError.queueEmpty }
        // Increment before the first queue mutation so handleTrackEnded /
        // handleGaplessTransition defer to this call during suspension points.
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        let ordered: [QueueItem]
        if shuffle {
            let seed = UInt64.random(in: .min ... .max)
            let clampedIndex = items.indices.contains(index) ? index : 0
            // Pin the chosen track at position 0 so double-clicking a track in shuffle
            // mode plays that track first, then shuffles the rest behind it.
            // This matches the behaviour of iTunes / Music / Spotify.
            // The explicitly chosen track is always kept even if it is marked
            // excludedFromShuffle — exclusion means "don't surface randomly", not
            // "never play".  All other excluded tracks are removed from the pool.
            let chosen = items[clampedIndex]
            let rest = items
                .enumerated()
                .filter { $0.offset != clampedIndex && !$0.element.excludedFromShuffle }
                .map(\.element)
            let shuffledRest = FisherYatesShuffle().shuffled(rest, seed: seed)
            ordered = [chosen] + shuffledRest
        } else {
            ordered = items
        }
        await self.queue.replace(with: ordered, startAt: shuffle ? 0 : index)
        if shuffle {
            await self.queue.setShuffle(true)
        }
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Insert `trackIDs` immediately after the current item.
    func playNext(_ trackIDs: [Int64]) async throws {
        let items = try await buildItems(for: trackIDs)
        await queue.appendNext(items)
    }

    /// Jump to and start playing the queue item at `index` in the existing queue.
    /// No-op when the index is out of range.  Preserves shuffle / repeat state —
    /// only the current cursor moves.  Used by the "Play From Here" Up Next
    /// context-menu action so users can resume from any point in the queue
    /// without rebuilding it.
    func playAt(index: Int) async throws {
        let snapshot = await self.queue.items
        guard snapshot.indices.contains(index) else { return }
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        await self.historyRecorder.trackSkipped(elapsed: self.engine.currentTime)
        await self.queue.replace(with: snapshot, startAt: index)
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Append `trackIDs` to the end of the queue.
    func addToQueue(_ trackIDs: [Int64]) async throws {
        let items = try await buildItems(for: trackIDs)
        await queue.append(items)
    }

    /// Append already-built items (e.g. streamed Subsonic songs) to the end of
    /// the queue. Used by drag-and-drop of `.subsonic` sources into Up Next (#332).
    func addToQueue(items: [QueueItem]) async {
        guard !items.isEmpty else { return }
        await self.queue.append(items)
    }

    /// Replace the queue with all tracks from `albumID` and start playing.
    /// Pass `shuffle: true` to shuffle before playback begins.
    func playAlbum(_ albumID: Int64, shuffle: Bool = false) async throws {
        let tracks = try await trackRepo.fetchAll(albumID: albumID)
        guard !tracks.isEmpty else {
            throw PlaybackError.queueEmpty
        }
        let ids = tracks.compactMap(\.id)
        let items = try await buildItems(for: ids)
        let ordered: [QueueItem]
        if shuffle {
            let seed = UInt64.random(in: .min ... .max)
            // Fall back to the full list if every track is excluded, so the user
            // isn't left with an empty queue after explicitly choosing this album.
            let eligible = items.filter { !$0.excludedFromShuffle }
            ordered = FisherYatesShuffle().shuffled(eligible.isEmpty ? items : eligible, seed: seed)
        } else {
            ordered = items
        }
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        await self.queue.replace(with: ordered, startAt: 0)
        if shuffle {
            await self.queue.setShuffle(true)
        }
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Replace the queue with all tracks by `artistID` and start playing.
    /// Pass `shuffle: true` to shuffle before playback begins.
    func playArtist(_ artistID: Int64, shuffle: Bool = false) async throws {
        let tracks = try await trackRepo.fetchAll(artistID: artistID)
        guard !tracks.isEmpty else {
            throw PlaybackError.queueEmpty
        }
        let ids = tracks.compactMap(\.id)
        let items = try await buildItems(for: ids)
        let ordered: [QueueItem]
        if shuffle {
            let seed = UInt64.random(in: .min ... .max)
            // Fall back to the full list if every track is excluded, so the user
            // isn't left with an empty queue after explicitly choosing this artist.
            let eligible = items.filter { !$0.excludedFromShuffle }
            ordered = FisherYatesShuffle().shuffled(eligible.isEmpty ? items : eligible, seed: seed)
        } else {
            ordered = items
        }
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        await self.queue.replace(with: ordered, startAt: 0)
        if shuffle {
            await self.queue.setShuffle(true)
        }
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Advance to the next item — or, when the current track carries CUE
    /// markers (ADR-087), jump to the next marker first; past the last one
    /// the queue advances as always.
    func next() async throws {
        if !self.currentMarkers.isEmpty {
            let elapsed = await engine.currentTime
            if let target = MarkerNavigation.nextTarget(markers: self.currentMarkers, elapsed: elapsed) {
                try await self.seek(to: target)
                return
            }
        }
        await self.gaplessScheduler.reset()
        await self.historyRecorder.trackSkipped(elapsed: self.engine.currentTime)

        // Use advanceManual so repeat-one is treated as repeat-all for user skips.
        // Repeat-one should only govern automatic end-of-track advance.
        guard let next = await queue.advanceManual() else {
            await self.stop()
            return
        }
        try await self.loadAndPlay(item: next)
    }

    /// Go back to the previous item (or start of current if < 3 s in). With
    /// CUE markers (ADR-087) the same restart threshold applies at marker
    /// granularity: restart the current marker when past it, jump to the
    /// previous marker otherwise; a track that has only just started still
    /// retreats to the previous queue item.
    func previous() async throws {
        let elapsed = await engine.currentTime
        switch MarkerNavigation.previousAction(markers: self.currentMarkers, elapsed: elapsed) {
        case let .seek(target):
            try await self.seek(to: target)

        case .retreat:
            await self.gaplessScheduler.reset()
            await self.historyRecorder.trackSkipped(elapsed: elapsed)
            guard let prev = await queue.retreat() else { return }
            try await self.loadAndPlay(item: prev)
        }
    }

    /// Toggle shuffle on/off.
    func setShuffle(_ on: Bool, strategy: (any ShuffleStrategy)? = nil) async {
        await self.queue.setShuffle(on)
    }

    /// Set the playback volume [0–1], forwarded to the audio engine.
    func setVolume(_ volume: Float) async {
        await self.engine.setVolume(volume)
    }

    /// Set pitch-preserving playback rate (0.5×–2.0×). Clamped by the DSP chain.
    func setRate(_ rate: Float) async {
        await self.engine.setRate(rate)
    }

    /// Change the repeat mode.
    func setRepeat(_ mode: RepeatMode) async {
        await self.queue.setRepeatMode(mode)
    }

    /// Enable or disable stop-after-current.
    ///
    /// When enabled, playback halts at the end of the current track, the flag
    /// auto-resets, and the queue position is preserved. If repeat-one is also
    /// active, stop-after-current wins.
    func setStopAfterCurrent(_ enabled: Bool) async {
        await self.queue.setStopAfterCurrent(enabled)
    }

    /// Update the crossfade configuration forwarded from `DSPViewModel`.
    ///
    /// When `config.durationSeconds > 0`, the next track fades in while the
    /// current one fades out, at every boundary between two local files.
    /// Same-album boundaries remain sample-accurate gapless when
    /// `config.albumGapless` is true (the default).
    func setCrossfadeConfig(_ config: CrossfadeScheduler.Config) async {
        await self.crossfadeScheduler.setConfig(config)
        self.log.debug("queueplayer.crossfade.config", [
            "durationSeconds": config.durationSeconds,
            "albumGapless": config.albumGapless,
        ])
    }

    /// The crossfade configuration in effect: the last one set, or crossfade
    /// off when none was.
    func crossfadeConfig() async -> CrossfadeScheduler.Config {
        await self.crossfadeScheduler.config
    }

    // MARK: Item building

    private func buildItems(for trackIDs: [Int64]) async throws -> [QueueItem] {
        // Fetch all artist names once up front rather than per-track. For a
        // 16k-track queue this collapses ~16,000 DB round-trips into one, which
        // is the difference between a sub-second replace and a multi-second stall.
        // An empty map builds the whole queue with blank artist names, which
        // reads as a library whose tags are missing (#494).
        var artists: [Artist] = []
        do {
            artists = try await self.artistRepo.fetchAll()
        } catch {
            self.log.warning("queueplayer.buildItems.artistsUnavailable", [
                "error": String(reflecting: error),
            ])
        }
        var artistNames: [Int64: String] = [:]
        artistNames.reserveCapacity(artists.count)
        for artist in artists {
            if let aid = artist.id {
                artistNames[aid] = artist.name
            }
        }
        var items: [QueueItem] = []
        items.reserveCapacity(trackIDs.count)
        for id in trackIDs {
            let track = try await trackRepo.fetch(id: id)
            let name = track.artistID.flatMap { artistNames[$0] }
            items.append(QueueItem.make(from: track, artistName: name))
        }
        return items
    }
}
