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

    // MARK: - Internal state

    private var currentTrack: Track?
    private var trackRepo: TrackRepository
    private var lastEmittedState: PlaybackState = .idle

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

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

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
        await queue.replace(with: items, startAt: index)
        try await self.loadCurrentItem()
        try await self.play()
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

    /// Advance to the next item.
    public func next() async throws {
        await self.gaplessScheduler.reset()
        await self.historyRecorder.trackSkipped(elapsed: self.engine.currentTime)

        guard let next = await queue.advance() else {
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

    /// Change the repeat mode.
    public func setRepeat(_ mode: RepeatMode) async {
        await self.queue.setRepeatMode(mode)
    }

    // MARK: Private helpers

    // MARK: Load + play

    private func loadCurrentItem() async throws {
        guard let item = await queue.currentItem else { return }
        try await self.loadAndPlay(item: item, autoPlay: false)
    }

    private func loadAndPlay(item: QueueItem, autoPlay: Bool = true) async throws {
        let url: URL
        do {
            url = try item.resolvedURL()
        } catch {
            self.log.error("queueplayer.url.failed", ["trackID": item.trackID, "error": String(reflecting: error)])
            throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
        }

        // Fetch track metadata (for NowPlaying).
        let track = try? await trackRepo.fetch(id: item.trackID)
        self.currentTrack = track

        try await self.engine.load(url)
        url.stopAccessingSecurityScopedResource()

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
        for await engineState in await self.engine.state {
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
        let elapsed = await engine.duration // track played fully
        await self.historyRecorder.trackDidEnd(elapsed: elapsed)

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

    private func resolveNextGaplessItem() async -> (url: URL, item: QueueItem)? {
        guard let item = await queue.peekNext() else { return nil }
        // Use fileURL directly (no security scope for gapless preload).
        // If the file requires a security scope, the decoder will throw and gapless
        // won't fire — QueuePlayer will fall back to normal stop/load/play.
        let url = URL(fileURLWithPath: item.fileURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url: url, item: item)
    }

    private func handleGaplessTransition(to item: QueueItem) async {
        // The engine has seamlessly transitioned to `item`. Advance queue state.
        _ = await self.queue.advance()

        // Update metadata for the new track.
        if let track = try? await trackRepo.fetch(id: item.trackID) {
            self.currentTrack = track
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

    // MARK: Item building

    private func buildItems(for trackIDs: [Int64]) async throws -> [QueueItem] {
        var items: [QueueItem] = []
        for id in trackIDs {
            let track = try await trackRepo.fetch(id: id)
            items.append(QueueItem.make(from: track))
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
