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

    let engine: AudioEngine
    private let database: Database
    let subsonicResolver: (any SubsonicStreamResolving)?
    let podcastResolver: (any PodcastEpisodeResolving)?

    // MARK: - Sub-systems

    public nonisolated let queue: PlaybackQueue // public for UI read access
    let gaplessScheduler: GaplessScheduler
    let crossfadeScheduler: CrossfadeScheduler
    let historyRecorder: PlayHistoryRecorder
    let persistence: QueuePersistence
    /// The sleep timer — available for UI observation via `LibraryViewModel`.
    public nonisolated let sleepTimer: SleepTimer

    // MARK: - @MainActor helpers (lazily initialised in activate())

    var nowPlayingCentre: NowPlayingCentre?
    var remoteCommands: RemoteCommands?

    // MARK: - Transport state stream

    public nonisolated let state: AsyncStream<PlaybackState>
    var stateContinuation: AsyncStream<PlaybackState>.Continuation?

    // MARK: - Current track stream

    /// Emits the currently-playing `Track` whenever it changes (including gapless
    /// transitions).  Emits `nil` when playback stops.
    public nonisolated let currentTrackChanges: AsyncStream<Track?>
    private var currentTrackContinuation: AsyncStream<Track?>.Continuation?

    // MARK: - Track ID changes stream (for EQ scope resolution)

    /// Emits `(trackID, albumID?)` whenever a new track starts loading.
    ///
    /// Separate from `currentTrackChanges` so DSP consumers don't compete with
    /// `NowPlayingViewModel` on the same single-consumer `AsyncStream`.
    /// Emits `(−1, nil)` when playback stops.
    public nonisolated let trackIDChanges: AsyncStream<(trackID: Int64, albumID: Int64?)>
    private var trackIDContinuation: AsyncStream<(trackID: Int64, albumID: Int64?)>.Continuation?

    // MARK: - Unavailable items stream

    /// Per-subscriber continuations, as `PlaybackQueue.changes()` uses. The
    /// queue view exists in the main window and the immersive window at the
    /// same time, and two iterators of one `AsyncStream` divide the elements
    /// between them, so one window would miss a set. Cancelling a single
    /// shared stream, which SwiftUI does whenever the view goes away, also
    /// ended it for every later subscriber (#545).
    var unavailableSubscribers: [UUID: AsyncStream<Set<QueueItem.ID>>.Continuation] = [:]
    private var _unavailableItemIDs: Set<QueueItem.ID> = []

    // MARK: - Schema warnings stream

    /// Emits a human-readable warning string when the persisted queue was written
    /// by a newer build of Bòcan whose schema this build cannot interpret.
    /// The queue is discarded and starts empty; the UI should surface the message
    /// as a toast so the user understands why their queue is gone.
    public nonisolated let schemaWarnings: AsyncStream<String>
    var schemaWarningContinuation: AsyncStream<String>.Continuation?

    // MARK: - Stream titles (ADR-078 slice 5)

    /// Live ICY now-playing titles, re-emitted for the UI. Yields only while
    /// the current item is internet radio; the same title also lands in
    /// `MPNowPlayingInfoCenter` via `NowPlayingCentre.updateStream`.
    public nonisolated let streamTitleUpdates: AsyncStream<String>
    private var streamTitleContinuation: AsyncStream<String>.Continuation?

    /// The current track's CUE markers (ADR-087), emitted on every load so
    /// the strip can draw scrubber ticks and the marker line. Empty for
    /// tracks without markers (and for radio, podcasts, and single-marker
    /// sets, which are inert by construction).
    public nonisolated let markerUpdates: AsyncStream<[TrackMarker]>
    var markerContinuation: AsyncStream<[TrackMarker]>.Continuation?
    /// Long-lived consumer of the engine's title stream; runs for the
    /// player's lifetime.
    private var titleObservationTask: Task<Void, Never>?

    /// Set once the deferred `activate()` has finished; until then,
    /// `waitUntilActivated` callers queue here.
    private var isActivated = false
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Internal state

    private var currentTrack: Track?
    /// The current track's markers (ADR-087), seconds-sorted; empty when the
    /// track has fewer than two (marker transport and display are inert then).
    var currentMarkers: [TrackMarker] = []
    var markerRepo: TrackMarkerRepository
    var trackRepo: TrackRepository
    var albumRepo: AlbumRepository
    var artistRepo: ArtistRepository
    var rootRepo: LibraryRootRepository
    var coverArtRepo: CoverArtRepository
    var lastEmittedState: PlaybackState = .idle

    /// Timestamp of the most recent gapless transition, used to suppress a
    /// spurious `.ended` signal that the new pump can emit within milliseconds
    /// of the transition before its first buffer has rendered.
    /// Only `.ended` events arriving within `gaplessSettleWindow` of the
    /// transition are swallowed; all later ones are treated as a genuine
    /// end-of-track so `handleTrackEnded` can advance the queue normally.
    var lastGaplessTransitionAt: Date?
    static let gaplessSettleWindow: TimeInterval = 3.0

    /// Number of in-flight `play(…)` calls that are currently replacing the queue.
    ///
    /// `handleTrackEnded` and `handleGaplessTransition` check this counter and bail
    /// out when it is non-zero.  Without this guard those callbacks can interleave
    /// with a `queue.replace` suspension and advance (or further mutate) the queue
    /// that `play(…)` is in the middle of replacing, causing the wrong track to load
    /// and — in the worst case — two pumps running simultaneously.
    var activeReplaceCount = 0

    // MARK: - Armed boundary state

    /// The next item and how the engine prepared the boundary into it
    /// (ADR-095, #574). A crossfade or gapless hand-over in the playing pump
    /// skips the settle window at its transition: no pump is swapped, so
    /// there is no spurious end to swallow, and an incoming track shorter
    /// than the window would otherwise lose its real end. Cleared by any
    /// manual load.
    var armedBoundary: (itemID: QueueItem.ID, preparation: NextTrackPreparation)?

    /// Periodic task that calls `historyRecorder.update(elapsed:)` while playing
    /// so that scrobbles fire at the 50 % threshold even before a track ends.
    var scrobbleUpdateTask: Task<Void, Never>?

    let log = AppLogger.make(.playback)

    // MARK: - Init

    public init(
        engine: AudioEngine,
        database: Database,
        scrobbleSink: (any ScrobbleSink)? = nil,
        subsonicResolver: (any SubsonicStreamResolving)? = nil,
        podcastResolver: (any PodcastEpisodeResolving)? = nil
    ) {
        self.engine = engine
        self.database = database
        self.subsonicResolver = subsonicResolver
        self.podcastResolver = podcastResolver
        self.queue = PlaybackQueue()
        self.historyRecorder = PlayHistoryRecorder(database: database, scrobbleSink: scrobbleSink)
        self.persistence = QueuePersistence(database: database)
        let crossfadeScheduler = CrossfadeScheduler()
        self.crossfadeScheduler = crossfadeScheduler
        self.gaplessScheduler = GaplessScheduler(engine: engine, crossfade: crossfadeScheduler)
        self.trackRepo = TrackRepository(database: database)
        self.albumRepo = AlbumRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.rootRepo = LibraryRootRepository(database: database)
        self.coverArtRepo = CoverArtRepository(database: database)
        self.markerRepo = TrackMarkerRepository(database: database)

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        var trackContinuation: AsyncStream<Track?>.Continuation?
        self.currentTrackChanges = AsyncStream { trackContinuation = $0 }
        self.currentTrackContinuation = trackContinuation

        var trackIDCont: AsyncStream<(trackID: Int64, albumID: Int64?)>.Continuation?
        self.trackIDChanges = AsyncStream { trackIDCont = $0 }
        self.trackIDContinuation = trackIDCont

        var schemaWarnContinuation: AsyncStream<String>.Continuation?
        self.schemaWarnings = AsyncStream { schemaWarnContinuation = $0 }
        self.schemaWarningContinuation = schemaWarnContinuation

        var titleContinuation: AsyncStream<String>.Continuation?
        self.streamTitleUpdates = AsyncStream { titleContinuation = $0 }
        self.streamTitleContinuation = titleContinuation

        var markerCont: AsyncStream<[TrackMarker]>.Continuation?
        self.markerUpdates = AsyncStream { markerCont = $0 }
        self.markerContinuation = markerCont

        // Build sleep timer — captures engine weakly so it can set volume / stop.
        self.sleepTimer = SleepTimer(
            onStop: { [weak engine] in await engine?.stop() },
            onSetVolume: { [weak engine] vol in await engine?.setVolume(vol) }
        )

        // Kick off async activation after init completes.
        // Use .medium priority so GRDB's internal DispatchQueue.sync calls
        // don't trigger the Thread Performance Checker priority-inversion warning
        // (GRDB pool uses sync dispatch internally; .userInitiated inherited from
        // @MainActor would cause the checker to flag an inversion).
        Task(priority: .medium) { await self.activate() }
    }

    /// Suspends until the deferred activation (now-playing helpers, engine
    /// and queue subscriptions, queue restore) has completed. Callers that
    /// mutate the queue right after construction (the App layer's E2E queue
    /// seeding is one) must await this first: a change emitted before the
    /// persistence subscription attaches is dropped and never saved.
    public func waitUntilActivated() async {
        if self.isActivated {
            return
        }
        await withCheckedContinuation { self.activationWaiters.append($0) }
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

        // Forward live ICY titles for the player's lifetime (ADR-078 slice 5).
        let engineTitles = self.engine.streamTitleUpdates
        self.titleObservationTask = Task { [weak self] in
            for await title in engineTitles {
                await self?.applyStreamTitle(title)
            }
        }

        // Configure gapless scheduler.
        await self.gaplessScheduler.configure(
            nextItemProvider: { [weak self] in
                await self?.resolveNextBoundary()
            },
            performPrefetch: { [weak self] item, transition in
                try await self?.performGaplessPrefetch(item: item, transition: transition)
            },
            onPrefetchFailed: { [weak self] _ in
                // Prefetch failure is non-fatal; normal end-of-track will trigger reload.
                Task { await self?.gaplessScheduler.reset() }
            }
        )
        await self.gaplessScheduler.start()

        // Subscribe to engine state (do not await — runs independently).
        Task { await self.subscribeToEngineState() }

        // Subscribe to queue changes for persistence. Attach the stream
        // synchronously: a change emitted before the subscriber exists is
        // dropped, so a queue mutation right after activation (the E2E
        // seed hook is one) would otherwise never be persisted.
        let queueChanges = await self.queue.changes()
        Task { await self.subscribeToQueueChanges(stream: queueChanges) }

        // Restore persisted queue state.
        await self.restoreQueue()

        // Restore sleep timer (resumes countdown if it was set before quit).
        await self.sleepTimer.restoreIfNeeded()

        self.isActivated = true
        let waiters = self.activationWaiters
        self.activationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
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
        // Persist a podcast position once before suspending, so a resume point
        // exists even between the 5 s ticks.
        await self.persistPodcastPositionIfNeeded()
        await self.engine.pause()
        await self.nowPlayingCentre?.setPlaying(false)
    }

    public func stop() async {
        await self.persistPodcastPositionIfNeeded()
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

    /// Stream facts from the engine's current decoder (ADR-078 slice 5); nil for
    /// AVFoundation-decoded local files.
    public var currentStreamDetails: StreamDetails? {
        get async { await self.engine.currentStreamDetails }
    }

    /// FFmpeg's short codec name for the engine's current decoder (ADR-092);
    /// nil between loads. Local files report it too, unlike the stream
    /// details above.
    public var currentCodec: String? {
        get async { await self.engine.currentCodec }
    }

    /// Re-emits a live ICY title while the current item is internet radio:
    /// once to the UI stream, once to `MPNowPlayingInfoCenter` with the
    /// station name moved into the artist slot.
    private func applyStreamTitle(_ title: String) async {
        guard let item = await self.queue.currentItem,
              case .internetRadio = item.playableSource else { return }
        self.streamTitleContinuation?.yield(title)
        let capturedEngine = self.engine
        await self.nowPlayingCentre?.updateStream(
            title: title,
            stationName: item.title ?? ""
        ) { await capturedEngine.currentTime }
    }

    // MARK: Remote commands

    private func bindRemoteCommands(_ commands: RemoteCommands) async {
        await MainActor.run {
            commands.onPlay = { [weak self] in
                await self?.runRemote(.play)
            }
            commands.onPause = { [weak self] in
                await self?.pause()
            }
            commands.onTogglePlayPause = { [weak self] in
                await self?.runRemote(.togglePlayPause)
            }
            commands.onNextTrack = { [weak self] in
                await self?.runRemote(.next)
            }
            commands.onPreviousTrack = { [weak self] in
                await self?.runRemote(.previous)
            }
            commands.onSeek = { [weak self] time in
                await self?.runRemote(.seek(time, label: "seek"))
            }
            commands.onSkipBack = { [weak self] interval in
                guard let self else { return }
                let current = await self.currentTime
                await self.runRemote(.seek(max(0, current - interval), label: "skipBack"))
            }
            commands.onSkipForward = { [weak self] interval in
                guard let self else { return }
                let current = await self.currentTime
                let dur = await self.duration
                await self.runRemote(.seek(min(dur, current + interval), label: "skipForward"))
            }
            commands.register()
        }
    }

    // MARK: Convenience

    /// Updates `currentTrack` and broadcasts the change on `currentTrackChanges`
    /// and `trackIDChanges`.
    func emitCurrentTrack(_ track: Track?) {
        self.currentTrack = track
        self.currentTrackContinuation?.yield(track)
        let tid: Int64 = track?.id ?? -1
        let aid: Int64? = track?.albumID
        self.trackIDContinuation?.yield((trackID: tid, albumID: aid))
    }

    // MARK: - Unavailable items

    /// Snapshot of queue-item IDs whose files are currently missing.
    /// Prefer ``unavailableItemUpdates()``, which yields this same set first
    /// and then keeps the caller up to date.
    public func unavailableItemIDs() -> Set<QueueItem.ID> {
        self._unavailableItemIDs
    }

    /// Emits the set of queue-item IDs whose backing files are missing: the
    /// current set first, then again whenever availability is recomputed
    /// (currently after `restoreQueue`). The UI observes this to render
    /// disabled rows for restored items pointing at deleted or moved files.
    ///
    /// Each call returns an independent stream, so two windows can both
    /// observe it, and one window going away leaves the other running. The
    /// subscriber is registered before the stream is returned, so nothing
    /// emitted after the call can be lost.
    public func unavailableItemUpdates() -> AsyncStream<Set<QueueItem.ID>> {
        let (stream, continuation) = AsyncStream.makeStream(of: Set<QueueItem.ID>.self)
        let id = UUID()
        self.unavailableSubscribers[id] = continuation
        continuation.yield(self._unavailableItemIDs)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeUnavailableSubscriber(id: id) }
        }
        return stream
    }

    private func removeUnavailableSubscriber(id: UUID) {
        self.unavailableSubscribers.removeValue(forKey: id)
    }

    /// Stores `ids` as the unavailable set and emits it to every subscriber.
    /// The stored set is private to this file, so `recomputeUnavailableItems`
    /// writes it through here.
    func storeAndEmitUnavailableItems(_ ids: Set<QueueItem.ID>) {
        self._unavailableItemIDs = ids
        self.emitUnavailableItems(ids)
    }
}
