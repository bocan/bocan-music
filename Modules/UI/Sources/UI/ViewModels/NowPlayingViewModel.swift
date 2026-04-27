import AppKit
import AudioEngine
import Foundation
import Observability
import Persistence
import Playback
import UserNotifications

// MARK: - NowPlayingViewModel

/// Drives the `NowPlayingStrip` at the bottom of every screen.
///
/// Subscribes to `Transport.state` on init and updates its `@Published`
/// properties on `@MainActor`.  Phase 5 will replace the concrete engine
/// with a `QueuePlayer` that also conforms to `Transport`.
@MainActor
public final class NowPlayingViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var title = ""
    @Published public private(set) var artist = ""
    @Published public private(set) var album = ""
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var isPlaying = false
    @Published public var volume: Float = 1.0
    @Published public private(set) var shuffleOn = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var stopAfterCurrent = false
    /// The database ID of the track currently loaded into the engine, or `nil`.
    @Published public private(set) var nowPlayingTrackID: Int64?
    /// `true` only while playback is paused mid-song (not stopped, idle, or ended).
    /// Used by `playPause()` to decide whether to resume or reload the library.
    @Published public private(set) var isPaused = false
    /// Current playback rate (0.5×–2.0×). Default 1.0×.
    @Published public private(set) var playbackRate: Float = 1.0
    /// Seconds remaining on the sleep timer, or `nil` when off.
    @Published public private(set) var sleepTimerRemaining: TimeInterval?
    /// Whether the sleep timer's fade-out option is active.
    @Published public private(set) var sleepTimerFadeOut = false

    // MARK: - Callbacks

    /// Called when play is pressed but the queue is empty and nothing is loaded.
    /// Set by `LibraryViewModel` to start playing the current library view.
    public var onPlayFromEmptyQueue: (@MainActor () -> Void)?

    // MARK: - Internal

    private let engine: any Transport
    private let database: Database
    private var stateTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var currentTrack: Track?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(engine: any Transport, database: Database) {
        self.engine = engine
        self.database = database
        self.startObservingState()
        if let qp = engine as? QueuePlayer {
            self.startObservingCurrentTrack(qp)
            self.startObservingSleepTimer(qp)
        }
    }

    // MARK: - Public API

    /// Set by the TracksView/AlbumsView when a track is selected and played.
    public func setCurrentTrack(_ track: Track) {
        self.log.info("playback.track", ["id": track.id ?? -1, "title": track.title ?? "?"])
        self.currentTrack = track
        self.nowPlayingTrackID = track.id
        self.title = track.title ?? "Unknown Track"
        self.artist = ""
        self.album = ""
        self.duration = track.duration
        self.artwork = nil

        Task {
            await self.resolveMetadata(for: track)
        }
    }

    /// Toggles play/pause on the engine.
    public func playPause() async {
        do {
            if self.isPlaying {
                await self.engine.pause()
            } else if self.isPaused {
                // Resume a song that was explicitly paused mid-playback.
                try await self.engine.play()
            } else {
                // Nothing is playing and nothing was paused — hand off to the
                // library callback so it queues the full current browse view.
                // This covers: first launch, queue exhausted, stale persisted queue.
                self.onPlayFromEmptyQueue?()
            }
        } catch {
            self.log.error("transport.playPause.failed", ["error": String(reflecting: error)])
        }
    }

    /// Seek to an absolute position.
    public func scrub(to time: TimeInterval) async {
        do {
            try await self.engine.seek(to: time)
        } catch {
            self.log.error("transport.seek.failed", ["error": String(reflecting: error)])
        }
    }

    /// Clamps and applies the volume to the engine.
    public func setVolume(_ newVolume: Float) async {
        self.volume = min(1, max(0, newVolume))
        await self.engine.setVolume(self.volume)
    }

    /// Skips to the previous track (no-op if engine is not a QueuePlayer).
    public func previous() async {
        guard let qp = engine as? QueuePlayer else { return }
        do { try await qp.previous() } catch {}
    }

    /// Skips to the next track (no-op if engine is not a QueuePlayer).
    public func next() async {
        guard let qp = engine as? QueuePlayer else { return }
        do { try await qp.next() } catch {}
    }

    /// Toggles shuffle on the queue player.
    public func toggleShuffle() async {
        guard let qp = engine as? QueuePlayer else { return }
        let new = !self.shuffleOn
        await qp.setShuffle(new)
        self.shuffleOn = new
    }

    /// Sets shuffle to an explicit value on the queue player.
    public func setShuffle(_ on: Bool) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setShuffle(on)
        self.shuffleOn = on
    }

    /// Cycles to the next repeat mode (off → all → one → off).
    public func cycleRepeat() async {
        guard let qp = engine as? QueuePlayer else { return }
        let next: RepeatMode = switch self.repeatMode {
        case .off:
            .all

        case .all:
            .one

        case .one:
            .off
        }
        await qp.setRepeat(next)
        self.repeatMode = next
    }

    /// Toggles the stop-after-current flag on the queue player.
    public func toggleStopAfterCurrent() async {
        guard let qp = engine as? QueuePlayer else { return }
        let new = !self.stopAfterCurrent
        await qp.setStopAfterCurrent(new)
        self.stopAfterCurrent = new
    }

    /// Set playback rate (0.5×–2.0×) with pitch correction.
    public func setRate(_ rate: Float) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setRate(rate)
        self.playbackRate = max(0.5, min(2.0, rate))
    }

    /// Configure the sleep timer.  Pass `nil` minutes to cancel.
    public func setSleepTimer(minutes: Int?, fadeOut: Bool = false) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.sleepTimer.set(minutes: minutes, fadeOut: fadeOut)
        self.sleepTimerFadeOut = fadeOut
        if minutes == nil { self.sleepTimerRemaining = nil }
    }

    private func startObservingCurrentTrack(_ qp: QueuePlayer) {
        Task { [weak self] in
            guard let self else { return }
            for await track in qp.currentTrackChanges {
                if let track {
                    self.setCurrentTrack(track)
                } else {
                    self.nowPlayingTrackID = nil
                    self.title = ""
                    self.artist = ""
                    self.album = ""
                    self.artwork = nil
                }
            }
        }
        // Observe queue changes to keep UI button state (shuffle, repeat,
        // stop-after-current) in sync with the actor's authoritative state.
        // Critical after restoreQueue() applies persisted values at launch — the
        // user should see the real repeat/shuffle mode, not the default.
        Task { [weak self] in
            guard let self else { return }
            // Seed from the actor's current state before listening for changes.
            let initialRepeat = await qp.queue.repeatMode
            let initialShuffle = await qp.queue.shuffleState
            let initialStopAfter = await qp.queue.stopAfterCurrent
            self.repeatMode = initialRepeat
            self.shuffleOn = initialShuffle != .off
            self.stopAfterCurrent = initialStopAfter

            for await change in qp.queue.changes {
                switch change {
                case let .stopAfterCurrentChanged(enabled):
                    self.stopAfterCurrent = enabled

                case let .repeatChanged(mode):
                    self.repeatMode = mode

                case let .shuffleChanged(state):
                    self.shuffleOn = state != .off

                default:
                    break
                }
            }
        }
    }

    private func startObservingSleepTimer(_ qp: QueuePlayer) {
        let timer = qp.sleepTimer
        self.sleepTimerTask = Task { [weak self] in
            // Poll the actor's remaining value at 1 s intervals to update the badge.
            while !Task.isCancelled {
                guard let self else { return }
                async let rem = timer.remaining
                async let fade = timer.fadeOut
                let (remaining, fadeOut) = await (rem, fade)
                self.sleepTimerRemaining = remaining
                self.sleepTimerFadeOut = fadeOut
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startObservingState() {
        self.stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.engine.state {
                guard !Task.isCancelled else { break }
                switch state {
                case .playing:
                    self.log.info("transport.state", ["state": "playing"])
                    self.isPlaying = true
                    self.isPaused = false
                    self.startPollingPosition()

                case .paused:
                    self.log.info("transport.state", ["state": "paused"])
                    self.isPlaying = false
                    self.isPaused = true
                    self.stopPollingPosition()

                case .stopped, .idle, .ended:
                    self.log.info("transport.state", ["state": String(describing: state)])
                    self.isPlaying = false
                    self.isPaused = false
                    self.stopPollingPosition()
                    if state == .ended { self.position = 0 }

                case .ready:
                    self.isPlaying = false

                case .loading, .failed:
                    break
                }
            }
        }
    }

    private func startPollingPosition() {
        self.stopPollingPosition()
        self.positionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let pos = await engine.currentTime
                let dur = await engine.duration
                await MainActor.run {
                    self.position = pos
                    if dur > 0 { self.duration = dur }
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            }
        }
    }

    private func stopPollingPosition() {
        self.positionTask?.cancel()
        self.positionTask = nil
    }
}

// MARK: - NowPlayingViewModel private helpers

private extension NowPlayingViewModel {
    func resolveMetadata(for track: Track) async {
        let trackID = track.id
        var artworkPath: String?
        do {
            // Resolve artist name
            if let artistID = track.artistID {
                let artistRecord = try await database.read { db in
                    try Artist.fetchOne(db, key: artistID)
                }
                await MainActor.run { self.artist = artistRecord?.name ?? "" }
            }

            // Resolve album name
            if let albumID = track.albumID {
                let albumRecord = try await database.read { db in
                    try Album.fetchOne(db, key: albumID)
                }
                await MainActor.run { self.album = albumRecord?.title ?? "" }

                // Resolve cover art
                if let hash = track.coverArtHash ?? albumRecord?.coverArtHash {
                    let artRecord = try await database.read { db in
                        try CoverArt.fetchOne(db, key: hash)
                    }
                    if let path = artRecord?.path {
                        artworkPath = path
                        let img = await ArtworkLoader.shared.image(at: path)
                        await MainActor.run { self.artwork = img }
                    }
                }
            }

            // Post track-change notification if still on the same track.
            guard self.nowPlayingTrackID == trackID else { return }
            await self.postTrackChangeNotification(
                title: self.title,
                artist: self.artist,
                artworkPath: artworkPath
            )
        } catch {
            self.log.error("nowplaying.resolve.failed", ["error": String(reflecting: error)])
        }
    }

    /// Posts a `UNNotification` banner when a new track starts, provided
    /// the user has enabled the setting and the app is not frontmost.
    func postTrackChangeNotification(title: String, artist: String, artworkPath: String?) async {
        let settingOn = UserDefaults.standard.bool(forKey: "general.showNotifications")
        let appActive = NSApp.isActive
        self.log.debug("notifications.attempt", ["settingOn": settingOn, "appActive": appActive, "title": title])
        guard settingOn else { return }
        guard !appActive else { return }

        // Bail early if the user hasn't granted permission rather than letting
        // the add() call fail silently.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            self.log.warning(
                "notifications.skipped",
                ["reason": "not authorized", "authStatus": String(describing: settings.authorizationStatus)]
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if !artist.isEmpty { content.subtitle = artist }
        content.sound = nil

        if let path = artworkPath {
            let url = URL(fileURLWithPath: path)
            if let attachment = try? UNNotificationAttachment(identifier: "artwork", url: url) {
                content.attachments = [attachment]
            }
        }

        // Re-using the same identifier replaces any still-visible previous banner.
        let request = UNNotificationRequest(
            identifier: "bocan.trackChange",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            self.log.error("notifications.add.failed", ["error": String(reflecting: error)])
        }
    }
}
