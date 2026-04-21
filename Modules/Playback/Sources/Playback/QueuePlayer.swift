import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer

/// The central playback coordinator.
///
/// `QueuePlayer` owns the audio engine and the playback queue, orchestrates
/// gapless preloading, forwards lock-screen / remote-control commands, records
/// play history, and persists queue state across app launches.
///
/// It conforms to `Transport` so existing UI code (`NowPlayingViewModel`) can
/// treat it as a drop-in replacement for `AudioEngine`.
///
/// **Threading model**: all state is actor-isolated.  `@MainActor` helpers
/// (`NowPlayingCentre`, `RemoteCommands`) are initialised asynchronously via
/// `activate()` and accessed with `await`.
public actor QueuePlayer: Transport {
    // MARK: - Dependencies

    private let engine: AudioEngine
    private let database: Database

    // MARK: - Sub-systems

    public nonisolated let queue: PlaybackQueue // public for UI read access
    private let gaplessScheduler: GaplessScheduler
    private let historyRecorder: PlayHistoryRecorder
    private let persistence: QueuePersistence

    // MARK: - @MainActor helpers (lazily initialised in activate())

    private var nowPlayingCentre: NowPlayingCentre?
    private var remoteCommands: RemoteCommands?

    // MARK: - Transport state stream

    public nonisolated let state: AsyncStream<PlaybackState>
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?

    // MARK: - Current track stream

    /// Emits the currently-playing `Track` whenever it changes (including gapless
    /// transitions).  Emits `nil` when playback stops.
    public nonisolated let currentTrackChanges: AsyncStream<Track?>
    private var currentTrackContinuation: AsyncStream<Track?>.Continuation?

    // MARK: - Internal state

    private var currentTrack: Track?
    private var trackRepo: TrackRepository
    private var albumRepo: AlbumRepository
    private var artistRepo: ArtistRepository
    private var rootRepo: LibraryRootRepository
    private var lastEmittedState: PlaybackState = .idle

    /// Item ID that `handleGaplessTransition` most recently advanced to.
    /// If `handleTrackEnded` fires while the queue's current item still
    /// matches this ID, a redundant `.ended` has been emitted for the old
    /// pump after the gapless transition already advanced the queue — in
    /// that case we swallow the event instead of advancing again.
    /// Cleared when the user manually skips, restarts, or a new track
    /// starts via the non-gapless path.
    private var lastGaplessAdvanceItemID: QueueItem.ID?

    /// Number of in-flight `play(…)` calls that are currently replacing the queue.
    ///
    /// `handleTrackEnded` and `handleGaplessTransition` check this counter and bail
    /// out when it is non-zero.  Without this guard those callbacks can interleave
    /// with a `queue.replace` suspension and advance (or further mutate) the queue
    /// that `play(…)` is in the middle of replacing, causing the wrong track to load
    /// and — in the worst case — two pumps running simultaneously.
    private var activeReplaceCount = 0

    private let log = AppLogger.make(.playback)

    // MARK: - Init

    public init(engine: AudioEngine, database: Database) {
        self.engine = engine
        self.database = database
        self.queue = PlaybackQueue()
        self.historyRecorder = PlayHistoryRecorder(database: database)
        self.persistence = QueuePersistence(database: database)
        self.gaplessScheduler = GaplessScheduler(engine: engine)
        self.trackRepo = TrackRepository(database: database)
        self.albumRepo = AlbumRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.rootRepo = LibraryRootRepository(database: database)

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        var trackContinuation: AsyncStream<Track?>.Continuation?
        self.currentTrackChanges = AsyncStream { trackContinuation = $0 }
        self.currentTrackContinuation = trackContinuation

        // Kick off async activation after init completes.
        Task { await self.activate() }
    }

    // MARK: - Async activation

    private func activate() async {
        // Initialise @MainActor helpers.
        let centre = await MainActor.run { NowPlayingCentre() }
        let commands = await MainActor.run { RemoteCommands() }
        self.nowPlayingCentre = centre
        self.remoteCommands = commands

        // Bind remote command handlers.
        await self.bindRemoteCommands(commands)

        // Configure gapless scheduler.
        await self.gaplessScheduler.configure(
            nextItemProvider: { [weak self] in
                await self?.resolveNextGaplessItem()
            },
            performPrefetch: { [weak self] item in
                try await self?.performGaplessPrefetch(item: item)
            },
            onGaplessTransition: { [weak self] item in
                await self?.handleGaplessTransition(to: item)
            },
            onPrefetchFailed: { [weak self] _ in
                // Prefetch failure is non-fatal; normal end-of-track will trigger reload.
                Task { await self?.gaplessScheduler.reset() }
            }
        )
        await self.gaplessScheduler.start()

        // Subscribe to engine state (do not await — runs independently).
        Task { await self.subscribeToEngineState() }

        // Subscribe to queue changes for persistence.
        Task { await self.subscribeToQueueChanges() }

        // Restore persisted queue state.
        await self.restoreQueue()

        self.log.debug("queueplayer.activated")
    }

    // MARK: - Transport conformance

    public func load(_ url: URL) async throws {
        await self.gaplessScheduler.reset()
        try await self.engine.load(url)
    }

    public func play() async throws {
        // If the engine hasn't loaded anything yet (idle or stopped state), try to
        // load the current queue item first so the play button always does something.
        if self.lastEmittedState == .idle || self.lastEmittedState == .stopped {
            // If the queue was exhausted (currentIndex became nil after reaching the
            // end) but still has items, restart from the beginning.
            if await self.queue.currentItem == nil, await !(self.queue.items.isEmpty) {
                await self.queue.seekToIndex(0)
            }
            if await (self.queue.currentItem) != nil {
                try await self.loadCurrentItem()
            }
        }
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    public func pause() async {
        await self.engine.pause()
        await self.nowPlayingCentre?.setPlaying(false)
    }

    public func stop() async {
        await self.engine.stop()
        await self.gaplessScheduler.stop()
        await self.nowPlayingCentre?.setPlaying(false)
        self.emitCurrentTrack(nil)
    }

    public func seek(to time: TimeInterval) async throws {
        try await self.engine.seek(to: time)
    }

    public var currentTime: TimeInterval {
        get async { await self.engine.currentTime }
    }

    public var duration: TimeInterval {
        get async { await self.engine.duration }
    }

    // MARK: - Queue operations

    /// Replace the queue with `trackIDs` and begin playing at `index`.
    public func play(trackIDs: [Int64], startingAt index: Int = 0) async throws {
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
    public func play(items: [QueueItem], startingAt index: Int = 0) async throws {
        guard !items.isEmpty else { throw PlaybackError.queueEmpty }
        // Increment before the first queue mutation so handleTrackEnded /
        // handleGaplessTransition defer to this call during suspension points.
        self.activeReplaceCount += 1
        defer { activeReplaceCount -= 1 }
        await self.gaplessScheduler.reset()
        await self.queue.replace(with: items, startAt: index)
        try await self.loadCurrentItem()
        try await self.engine.play()
        await self.nowPlayingCentre?.setPlaying(true)
    }

    /// Insert `trackIDs` immediately after the current item.
    public func playNext(_ trackIDs: [Int64]) async throws {
        let items = try await buildItems(for: trackIDs)
        await queue.appendNext(items)
    }

    /// Append `trackIDs` to the end of the queue.
    public func addToQueue(_ trackIDs: [Int64]) async throws {
        let items = try await buildItems(for: trackIDs)
        await queue.append(items)
    }

    /// Replace the queue with all tracks from `albumID` and start playing.
    /// Pass `shuffle: true` to shuffle before playback begins.
    public func playAlbum(_ albumID: Int64, shuffle: Bool = false) async throws {
        let tracks = try await trackRepo.fetchAll(albumID: albumID)
        guard !tracks.isEmpty else {
            throw PlaybackError.queueEmpty
        }
        let ids = tracks.compactMap(\.id)
        let items = try await buildItems(for: ids)
        let ordered: [QueueItem]
        if shuffle {
            let seed = UInt64.random(in: .min ... .max)
            ordered = FisherYatesShuffle().shuffled(items, seed: seed)
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
    public func playArtist(_ artistID: Int64, shuffle: Bool = false) async throws {
        let tracks = try await trackRepo.fetchAll(artistID: artistID)
        guard !tracks.isEmpty else {
            throw PlaybackError.queueEmpty
        }
        let ids = tracks.compactMap(\.id)
        let items = try await buildItems(for: ids)
        let ordered: [QueueItem]
        if shuffle {
            let seed = UInt64.random(in: .min ... .max)
            ordered = FisherYatesShuffle().shuffled(items, seed: seed)
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

    /// Advance to the next item.
    public func next() async throws {
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

    /// Go back to the previous item (or start of current if < 3 s in).
    public func previous() async throws {
        let elapsed = await engine.currentTime
        if elapsed > 3.0 {
            // Restart current track.
            try await self.seek(to: 0)
            return
        }
        await self.gaplessScheduler.reset()
        await self.historyRecorder.trackSkipped(elapsed: elapsed)
        guard let prev = await queue.retreat() else { return }
        try await self.loadAndPlay(item: prev)
    }

    /// Toggle shuffle on/off.
    public func setShuffle(_ on: Bool, strategy: (any ShuffleStrategy)? = nil) async {
        await self.queue.setShuffle(on)
    }

    /// Set the playback volume [0–1], forwarded to the audio engine.
    public func setVolume(_ volume: Float) async {
        await self.engine.setVolume(volume)
    }

    /// Change the repeat mode.
    public func setRepeat(_ mode: RepeatMode) async {
        await self.queue.setRepeatMode(mode)
    }

    /// Enable or disable stop-after-current.
    ///
    /// When enabled, playback halts at the end of the current track, the flag
    /// auto-resets, and the queue position is preserved. If repeat-one is also
    /// active, stop-after-current wins.
    public func setStopAfterCurrent(_ enabled: Bool) async {
        await self.queue.setStopAfterCurrent(enabled)
    }

    // MARK: Private helpers

    // MARK: Load + play

    private func loadCurrentItem() async throws {
        guard let item = await queue.currentItem else { return }
        try await self.loadAndPlay(item: item, autoPlay: false)
    }

    private func loadAndPlay(item: QueueItem, autoPlay: Bool = true) async throws {
        // A non-gapless load means no prior gapless transition is "pending",
        // so clear the guard.  (Handles manual skips, repeat-one replays,
        // and the normal-fallback path when gapless prefetch failed.)
        self.lastGaplessAdvanceItemID = nil

        // Resolve a playable URL.
        //
        // Priority order:
        //  1. Per-file security-scoped bookmark (stored at scan time).
        //  2. Root-folder security-scoped bookmark (covers all files under the root).
        //
        // We go directly to the root scope when the per-file bookmark is absent (nil)
        // because the raw file:// URL is inaccessible in the sandbox without a scope.
        var resolvedFromPerFileBookmark = false
        var scopedRootURL: URL? = nil
        let url: URL

        if item.bookmark != nil {
            // Attempt per-file bookmark first.
            do {
                url = try item.resolvedURL()
                resolvedFromPerFileBookmark = true
            } catch {
                self.log.warning(
                    "queueplayer.url.bookmark_failed",
                    ["trackID": item.trackID, "error": String(reflecting: error)]
                )
                // Per-file bookmark stale/invalid — fall back to root scope.
                guard let rawURL = URL(string: item.fileURL) else {
                    self.log.error("queueplayer.url.bad_file_url", ["trackID": item.trackID, "url": item.fileURL])
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                guard let rootURL = try await self.startRootScope(for: item.fileURL) else {
                    self.log.error("queueplayer.url.no_root", ["trackID": item.trackID])
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                scopedRootURL = rootURL
                url = rawURL
            }
        } else {
            // No per-file bookmark — use root scope directly to stay within sandbox.
            self.log.debug("queueplayer.url.no_per_file_bookmark", ["trackID": item.trackID])
            guard let rawURL = URL(string: item.fileURL) else {
                self.log.error("queueplayer.url.bad_file_url", ["trackID": item.trackID, "url": item.fileURL])
                throw PlaybackError.bookmarkResolutionFailed(
                    trackID: item.trackID,
                    underlying: URLError(.badURL)
                )
            }
            if let rootURL = try await self.startRootScope(for: item.fileURL) {
                scopedRootURL = rootURL
            } else {
                // No root scope found — attempt raw URL anyway (works outside sandbox).
                self.log.warning("queueplayer.url.no_root_scope", ["trackID": item.trackID])
            }
            url = rawURL
        }

        // Fetch track metadata (for NowPlaying).
        let track = try? await trackRepo.fetch(id: item.trackID)
        self.emitCurrentTrack(track)

        try await self.engine.load(url)
        // Release whichever scope was started — AVAudioFile already holds an open
        // file descriptor so the scope is no longer needed.
        if resolvedFromPerFileBookmark {
            url.stopAccessingSecurityScopedResource()
        }
        scopedRootURL?.stopAccessingSecurityScopedResource()

        if let track {
            let capturedEngine = self.engine
            await self.nowPlayingCentre?.update(
                track: track,
                duration: item.duration,
                positionProvider: { await capturedEngine.currentTime }
            )
        }

        await self.historyRecorder.trackDidStart(trackID: item.trackID, duration: item.duration)

        if autoPlay {
            try await self.engine.play()
            await self.nowPlayingCentre?.setPlaying(true)
        }

        self.log.debug("queueplayer.loaded", ["trackID": item.trackID])
    }

    // MARK: Engine state subscription

    private func subscribeToEngineState() async {
        for await engineState in self.engine.state {
            switch engineState {
            case .ended:
                await self.handleTrackEnded()
            case .playing:
                self.lastEmittedState = .playing
                self.stateContinuation?.yield(.playing)
                await self.gaplessScheduler.start()
            case .paused:
                self.lastEmittedState = .paused
                self.stateContinuation?.yield(.paused)
            default:
                self.lastEmittedState = engineState
                self.stateContinuation?.yield(engineState)
            }
        }
    }

    private func handleTrackEnded() async {
        // A play(…) call is in the middle of replacing the queue — it will load and
        // start the new track itself.  Advancing here would corrupt the new queue.
        guard self.activeReplaceCount == 0 else {
            self.log.debug("queueplayer.ended.deferredToPlay", [:])
            return
        }
        let elapsed = await engine.duration // track played fully
        await self.historyRecorder.trackDidEnd(elapsed: elapsed)

        // If a gapless transition has already advanced the queue to the
        // currently active item, a late `.ended` from the previous pump
        // must not trigger another advance.  Swallow and clear the flag.
        if let lastID = self.lastGaplessAdvanceItemID,
           let current = await queue.currentItem,
           current.id == lastID {
            self.lastGaplessAdvanceItemID = nil
            self.log.debug("queueplayer.ended.swallowed.afterGapless", ["itemID": lastID])
            return
        }

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
            self.log.error("queueplayer.advance.failed", ["error": String(reflecting: error)])
            self.stateContinuation?.yield(.failed(AudioEngineError.decoderFailure(codec: "unknown", underlying: error)))
        }
    }

    // MARK: Gapless next URL resolution

    private func resolveNextGaplessItem() async -> (item: QueueItem, forceGapless: Bool)? {
        guard let item = await queue.peekNext() else { return nil }

        // Determine whether the next item's album has `force_gapless` set and
        // the current item belongs to the same album.
        var forceGapless = false
        if let nextAlbumID = item.albumID,
           let currentItem = await queue.currentItem,
           let currentAlbumID = currentItem.albumID,
           currentAlbumID == nextAlbumID,
           let album = try? await albumRepo.fetch(id: nextAlbumID) {
            forceGapless = album.forceGapless
        }

        return (item: item, forceGapless: forceGapless)
    }

    /// Resolve the next item's URL into a security-scoped URL, call
    /// `engine.enableGaplessNext`, and release the scope once the decoder has
    /// opened the file.  Mirrors the scope-handling pattern in `loadAndPlay`.
    ///
    /// Without this, gapless prefetch fails outside the sandbox with
    /// "Access denied" because the raw `file://` URL has no permission grant.
    private func performGaplessPrefetch(item: QueueItem) async throws {
        // Resolve the URL the same way we would for a normal load.
        var resolvedFromPerFileBookmark = false
        var scopedRootURL: URL? = nil
        let url: URL

        if item.bookmark != nil {
            do {
                url = try item.resolvedURL()
                resolvedFromPerFileBookmark = true
            } catch {
                // Per-file bookmark stale/invalid — fall back to root scope.
                guard let rawURL = URL(string: item.fileURL) else {
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                guard let rootURL = try await self.startRootScope(for: item.fileURL) else {
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                scopedRootURL = rootURL
                url = rawURL
            }
        } else {
            guard let rawURL = URL(string: item.fileURL) else {
                throw PlaybackError.bookmarkResolutionFailed(
                    trackID: item.trackID,
                    underlying: URLError(.badURL)
                )
            }
            if let rootURL = try await self.startRootScope(for: item.fileURL) {
                scopedRootURL = rootURL
            }
            url = rawURL
        }

        // Fail early if the file is unreachable — avoids opaque AVAudioFile errors.
        guard FileManager.default.fileExists(atPath: url.path) else {
            if resolvedFromPerFileBookmark { url.stopAccessingSecurityScopedResource() }
            scopedRootURL?.stopAccessingSecurityScopedResource()
            throw PlaybackError.bookmarkResolutionFailed(
                trackID: item.trackID,
                underlying: URLError(.fileDoesNotExist)
            )
        }

        let capturedItem = item
        let onTransitionCallback = self.onGaplessTransitionCaptured

        do {
            try await self.engine.enableGaplessNext(url: url) {
                Task { @Sendable in
                    await onTransitionCallback?(capturedItem)
                }
            }
        } catch {
            if resolvedFromPerFileBookmark { url.stopAccessingSecurityScopedResource() }
            scopedRootURL?.stopAccessingSecurityScopedResource()
            throw error
        }

        // The decoder has opened the file; release scope.
        if resolvedFromPerFileBookmark {
            url.stopAccessingSecurityScopedResource()
        }
        scopedRootURL?.stopAccessingSecurityScopedResource()
    }

    /// Captured reference to the transition handler so `performGaplessPrefetch`
    /// can invoke it from a `@Sendable` closure without re-capturing `self`.
    private var onGaplessTransitionCaptured: (@Sendable (QueueItem) async -> Void)? {
        { [weak self] item in await self?.handleGaplessTransition(to: item) }
    }

    private func handleGaplessTransition(to item: QueueItem) async {
        // A play(…) call is replacing the queue — ignore the stale gapless event.
        guard self.activeReplaceCount == 0 else {
            self.log.debug("queueplayer.gapless.deferredToPlay", [:])
            return
        }
        // The engine has seamlessly transitioned to `item`. Advance queue state.
        _ = await self.queue.advance()
        self.lastGaplessAdvanceItemID = item.id

        // Update metadata for the new track.
        if let track = try? await trackRepo.fetch(id: item.trackID) {
            self.emitCurrentTrack(track)
            let capturedEngine = self.engine
            await self.nowPlayingCentre?.update(
                track: track,
                duration: item.duration,
                positionProvider: { await capturedEngine.currentTime }
            )
        }

        await self.historyRecorder.trackDidStart(trackID: item.trackID, duration: item.duration)
        self.log.debug("queueplayer.gapless.transition", ["trackID": item.trackID])
    }

    // MARK: Queue change subscription (for persistence)

    private func subscribeToQueueChanges() async {
        for await _ in self.queue.changes {
            let items = await queue.items
            let currentIndex = await queue.currentIndex
            let repeatMode = await queue.repeatMode
            let shuffleState = await queue.shuffleState
            await self.persistence.scheduleSave(
                items: items,
                currentIndex: currentIndex,
                repeatMode: repeatMode,
                shuffleState: shuffleState
            )
        }
    }

    // MARK: Queue restore

    private func restoreQueue() async {
        guard let saved = await persistence.restore() else { return }
        await self.queue.replace(with: saved.items, startAt: saved.currentIndex ?? 0)
        await self.queue.setRepeatMode(saved.repeatMode)
        if case let .on(seed) = saved.shuffleState {
            await self.queue.setShuffle(true, seed: seed)
        }
        self.log.debug("queueplayer.queue.restored", ["count": saved.items.count])
    }

    // MARK: Root-scope fallback

    /// Updates `currentTrack` and broadcasts the change on `currentTrackChanges`.
    private func emitCurrentTrack(_ track: Track?) {
        self.currentTrack = track
        self.currentTrackContinuation?.yield(track)
    }

    /// Finds the library root that contains `fileURLString`, resolves its
    /// security-scoped bookmark, starts accessing the scope, and returns the
    /// scoped root URL.  The caller is responsible for calling
    /// `stopAccessingSecurityScopedResource()` on the returned URL.
    ///
    /// Returns `nil` when no matching root is found or when the root bookmark
    /// cannot be resolved.
    private func startRootScope(for fileURLString: String) async throws -> URL? {
        let roots = await (try? self.rootRepo.fetchAll()) ?? []
        // fileURLString is stored as url.absoluteString ("file:///path/to/file.mp3")
        // while root.path is url.path ("/path/to/folder") — compare via the path component.
        guard let filePath = URL(string: fileURLString)?.path,
              let root = roots.first(where: { filePath.hasPrefix($0.path) }) else {
            return nil
        }
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: root.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard rootURL.startAccessingSecurityScopedResource() else { return nil }
        return rootURL
    }

    // MARK: Item building

    private func buildItems(for trackIDs: [Int64]) async throws -> [QueueItem] {
        // Fetch all artist names once up front rather than per-track. For a
        // 16k-track queue this collapses ~16,000 DB round-trips into one, which
        // is the difference between a sub-second replace and a multi-second stall.
        let artists = await (try? self.artistRepo.fetchAll()) ?? []
        var artistNames: [Int64: String] = [:]
        artistNames.reserveCapacity(artists.count)
        for a in artists {
            if let aid = a.id { artistNames[aid] = a.name }
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

    // MARK: Remote commands

    private func bindRemoteCommands(_ commands: RemoteCommands) async {
        await MainActor.run {
            commands.onPlay = { [weak self] in
                guard let self else { return }
                try? await self.play()
            }
            commands.onPause = { [weak self] in
                await self?.pause()
            }
            commands.onTogglePlayPause = { [weak self] in
                await self?.togglePlayPause()
            }
            commands.onNextTrack = { [weak self] in
                try? await self?.next()
            }
            commands.onPreviousTrack = { [weak self] in
                try? await self?.previous()
            }
            commands.onSeek = { [weak self] time in
                try? await self?.seek(to: time)
            }
            commands.register()
        }
    }

    // MARK: Convenience

    private func togglePlayPause() async {
        if case .playing = self.lastEmittedState {
            await self.pause()
        } else {
            try? await self.play()
        }
    }
}
