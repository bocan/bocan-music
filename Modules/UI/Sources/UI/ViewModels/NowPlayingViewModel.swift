// swiftlint:disable file_length
import AppKit
import AudioEngine
import Foundation
import Observability
import Persistence
import Playback
import Scrobble
import Subsonic
import UserNotifications

// MARK: - NowPlayingViewModel

/// Drives the `NowPlayingStrip` at the bottom of every screen.
///
/// Subscribes to `Transport.state` on init and updates its observable
/// properties on `@MainActor`.
@Observable
@MainActor
public final class NowPlayingViewModel {
    // MARK: - Observable state

    /// Cover art for the current track, or `nil` when nothing is playing.
    public private(set) var artwork: NSImage?
    /// Track title of the current item, or empty string when idle.
    public private(set) var title = ""
    /// Primary artist of the current item.
    public private(set) var artist = ""
    /// Album name of the current item.
    public private(set) var album = ""
    /// Total duration of the current track in seconds.
    public private(set) var duration: TimeInterval = 0
    /// Current playback position in seconds.
    public private(set) var position: TimeInterval = 0
    /// `true` while the engine is actively playing.
    public private(set) var isPlaying = false
    /// Output volume in the range 0.0–1.0.
    public var volume: Float = 1.0
    /// `true` when shuffle mode is active.
    public private(set) var shuffleOn = false
    /// Current repeat mode (.off / .one / .all).
    public private(set) var repeatMode: RepeatMode = .off
    /// `true` when "stop after current track" is armed.
    public private(set) var stopAfterCurrent = false
    /// The database ID of the track currently loaded into the engine, or `nil`.
    public private(set) var nowPlayingTrackID: Int64?
    /// The album ID of the track currently loaded into the engine, or `nil`.
    public private(set) var nowPlayingAlbumID: Int64?
    /// The artist ID of the track currently loaded into the engine, or `nil`.
    public private(set) var nowPlayingArtistID: Int64?
    /// The Subsonic server ID of the stream currently loaded into the engine, or
    /// `nil` when the current item is not a Subsonic stream.
    public private(set) var nowPlayingSubsonicServerID: UUID?
    /// The Subsonic song ID of the stream currently loaded into the engine, or
    /// `nil` when the current item is not a Subsonic stream. Together with
    /// `nowPlayingSubsonicServerID` this lets per-server Songs lists move their
    /// selection onto the playing row, mirroring the local library.
    public private(set) var nowPlayingSubsonicSongID: String?
    /// `true` only while playback is paused mid-song (not stopped, idle, or ended).
    /// Used by `playPause()` to decide whether to resume or reload the library.
    public private(set) var isPaused = false
    /// Current playback rate (0.5×–2.0×). Default 1.0×.
    public private(set) var playbackRate: Float = 1.0
    /// `true` when the output is muted (volume forced to 0 without forgetting the real level).
    public private(set) var isMuted = false
    /// Seconds remaining on the sleep timer, or `nil` when off.
    public private(set) var sleepTimerRemaining: TimeInterval?
    /// Whether the sleep timer's fade-out option is active.
    public private(set) var sleepTimerFadeOut = false
    /// The number of minutes the active sleep timer was set to, or `nil` when off.
    /// Used by the Playback menu to show a checkmark next to the active preset.
    public private(set) var sleepTimerActiveMinutes: Int?
    /// Number of scrobbles pending submission. Sourced from `ScrobbleQueueRepository.observeStats()`.
    /// Zero when scrobbling is not configured. Used to drive the strip indicator.
    public private(set) var pendingScrobbleCount = 0
    /// `true` when the currently-playing (or paused) track is marked as loved.
    public private(set) var nowPlayingIsLoved = false

    // MARK: - Callbacks

    /// Called when play is pressed but the queue is empty; set by `LibraryViewModel`.
    public var onPlayFromEmptyQueue: (@MainActor () -> Void)?

    // MARK: - Internal

    private let engine: any Transport
    private let database: Database
    private let subsonicCoverArtProvider: SubsonicCoverArtProvider?
    // nonisolated(unsafe): assigned only from @MainActor methods and read once
    // from the nonisolated `deinit`, which has exclusive access — never
    // concurrently. Task handles are themselves Sendable. See #279.
    private nonisolated(unsafe) var stateTask: Task<Void, Never>?
    private nonisolated(unsafe) var positionTask: Task<Void, Never>?
    private nonisolated(unsafe) var sleepTimerTask: Task<Void, Never>?
    private nonisolated(unsafe) var scrobbleStatsTask: Task<Void, Never>?
    private nonisolated(unsafe) var currentTrackTask: Task<Void, Never>?
    private nonisolated(unsafe) var queueChangesTask: Task<Void, Never>?
    /// The full `Track` record for the currently-playing item, or `nil` when idle.
    /// Populated by `setCurrentTrack(_:)` and used by `TrackInfoPanel`.
    public private(set) var currentTrack: Track?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    /// Creates a new `NowPlayingViewModel` bound to the given transport and database.
    /// Pass `scrobbleRepository` to show the pending-scrobbles indicator in the strip.
    public init(
        engine: any Transport,
        database: Database,
        scrobbleRepository: ScrobbleQueueRepository? = nil,
        subsonicCoverArtProvider: SubsonicCoverArtProvider? = nil
    ) {
        self.engine = engine
        self.database = database
        self.subsonicCoverArtProvider = subsonicCoverArtProvider
        self.startObservingState()
        if let qp = engine as? QueuePlayer {
            self.startObservingCurrentTrack(qp)
            self.startObservingSleepTimer(qp)
        }
        if let storedRate = UserDefaults.standard.object(forKey: "playback.rate") as? Double {
            let r = max(0.5, min(2.0, Float(storedRate)))
            self.playbackRate = r
            Task { await self.setRate(r) }
        }
        if let repo = scrobbleRepository {
            self.startObservingScrobbleStats(repo)
        }
    }

    deinit {
        // Cancel every long-lived observation loop. These closures all capture
        // [weak self] so they no-op once the VM is gone, but leaving the tasks
        // running is untidy and a real leak should the VM ever become per-window
        // rather than app-lifetime. Task.cancel() is safe from a nonisolated
        // deinit; the stored handles are Sendable. See #279.
        self.stateTask?.cancel()
        self.positionTask?.cancel()
        self.sleepTimerTask?.cancel()
        self.scrobbleStatsTask?.cancel()
        self.currentTrackTask?.cancel()
        self.queueChangesTask?.cancel()
    }

    private func startObservingScrobbleStats(_ repo: ScrobbleQueueRepository) {
        self.scrobbleStatsTask = Task { [weak self] in
            do {
                for try await stats in repo.observeStats() {
                    self?.pendingScrobbleCount = stats.pending
                }
            } catch {
                AppLogger.make(.scrobble).warning(
                    "scrobble.nowPlaying.stats.failed",
                    ["error": String(reflecting: error)]
                )
            }
        }
    }

    // MARK: - Public API

    /// Set by the TracksView/AlbumsView when a track is selected and played.
    public func setCurrentTrack(_ track: Track) {
        self.log.info("playback.track", ["id": track.id ?? -1, "title": track.title ?? "?"])
        self.currentTrack = track
        self.nowPlayingTrackID = track.id
        self.nowPlayingAlbumID = track.albumID
        self.nowPlayingArtistID = track.artistID
        // A local track is not a Subsonic stream; drop any stale stream identity.
        self.nowPlayingSubsonicServerID = nil
        self.nowPlayingSubsonicSongID = nil
        self.nowPlayingIsLoved = track.loved
        self.title = track.title ?? "Unknown Track"
        self.artist = ""
        self.album = ""
        self.duration = track.duration
        self.artwork = nil

        Task {
            await self.resolveMetadata(for: track)
        }
    }

    /// Updates the loved state for the currently-playing track.
    /// Called by `LibraryViewModel.applyLoved` when the now-playing track is in the updated set.
    public func updateNowPlayingLoved(_ loved: Bool) {
        self.nowPlayingIsLoved = loved
    }

    /// Toggles play/pause on the engine.
    public func playPause() async {
        do {
            if self.isPlaying {
                await self.engine.pause()
            } else if self.isPaused || self.nowPlayingTrackID != nil {
                // Resume: either explicitly paused mid-playback, or stopped after a
                // session restore (engine loaded a track but never called play()).
                // QueuePlayer.play() handles the stopped-with-queue case internally,
                // so this correctly resumes the restored (possibly shuffled) queue
                // without discarding it.
                try await self.engine.play()
            } else {
                // Nothing is playing, nothing was paused, and no track has ever been
                // loaded — hand off to the library callback so it queues the full
                // current browse view.  Covers first launch and cleared queues.
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

    /// Clamps and applies volume to the engine; preserves mute state.
    public func setVolume(_ newVolume: Float) async {
        self.volume = min(1, max(0, newVolume))
        if !self.isMuted {
            await self.engine.setVolume(self.volume)
        }
    }

    /// Toggles mute; preserves stored volume so unmuting restores the previous level.
    public func toggleMute() async {
        if self.isMuted {
            self.isMuted = false
            await self.engine.setVolume(self.volume)
        } else {
            self.isMuted = true
            await self.engine.setVolume(0)
        }
    }

    /// Steps volume up by 10%, clamped to 1.0.
    public func increaseVolume() async {
        await self.setVolume(min(1.0, self.volume + 0.1))
    }

    /// Steps volume down by 10%, clamped to 0.0.
    public func decreaseVolume() async {
        await self.setVolume(max(0.0, self.volume - 0.1))
    }

    /// Skips to previous, or restarts current track if past the 3-second threshold.
    public func previous() async {
        let pos = await self.engine.currentTime
        if pos > 3.0 {
            await self.scrub(to: 0)
        } else {
            guard let qp = self.engine as? QueuePlayer else { return }
            do { try await qp.previous() } catch {
                self.log.error("transport.previous.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Restarts the current track from position 0, regardless of position.
    public func restartTrack() async {
        await self.scrub(to: 0)
    }

    /// Skips to the next track (no-op if engine is not a QueuePlayer).
    public func next() async {
        guard let qp = engine as? QueuePlayer else { return }
        do { try await qp.next() } catch {
            self.log.error("transport.next.failed", ["error": String(reflecting: error)])
        }
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
        UserDefaults.standard.set(Double(self.playbackRate), forKey: "playback.rate")
    }

    /// Steps up to the next quick rate above the current rate.
    public func increaseSpeed() async {
        let next = Self.quickRates.first { $0 > self.playbackRate + 0.01 }
        await self.setRate(next ?? 2.0)
    }

    /// Steps down to the next quick rate below the current rate.
    public func decreaseSpeed() async {
        let prev = Self.quickRates.last { $0 < self.playbackRate - 0.01 }
        await self.setRate(prev ?? 0.75)
    }

    /// Resets playback speed to 1.0×.
    public func resetSpeed() async {
        await self.setRate(1.0)
    }

    /// Quick-pick rates shared with `SpeedPickerView` and the Playback menu.
    public static let quickRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// Sleep timer presets shared with the Playback menu.
    public static let sleepPresets: [(label: String, minutes: Int?)] = [
        ("Off", nil),
        ("15 min", 15),
        ("30 min", 30),
        ("45 min", 45),
        ("1 hr", 60),
        ("1 hr 30 min", 90),
        ("2 hr", 120),
    ]

    /// Configure the sleep timer.  Pass `nil` minutes to cancel.
    public func setSleepTimer(minutes: Int?, fadeOut: Bool = false) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.sleepTimer.set(minutes: minutes, fadeOut: fadeOut)
        self.sleepTimerFadeOut = fadeOut
        self.sleepTimerActiveMinutes = minutes
        if minutes == nil { self.sleepTimerRemaining = nil }
    }

    /// Populates the now-playing display from a queue item that has no local
    /// `Track` row (e.g. a Subsonic stream), using the item's snapshot metadata.
    private func applyStreamItem(_ item: QueueItem) async {
        self.nowPlayingTrackID = nil
        self.nowPlayingAlbumID = nil
        self.nowPlayingArtistID = nil
        self.title = item.title ?? "Unknown Track"
        self.artist = item.artistName ?? ""
        self.album = item.albumName ?? ""
        self.duration = item.duration
        self.artwork = nil
        if case let .subsonic(serverID, songID) = item.playableSource {
            self.nowPlayingSubsonicServerID = serverID
            self.nowPlayingSubsonicSongID = songID
            await self.loadSubsonicArtwork(serverID: serverID, songID: songID)
        } else {
            self.nowPlayingSubsonicServerID = nil
            self.nowPlayingSubsonicSongID = nil
        }
    }

    /// Resets every now-playing display field; called when the queue is empty.
    private func clearNowPlayingDisplay() {
        self.nowPlayingTrackID = nil
        self.nowPlayingAlbumID = nil
        self.nowPlayingArtistID = nil
        self.nowPlayingSubsonicServerID = nil
        self.nowPlayingSubsonicSongID = nil
        self.title = ""
        self.artist = ""
        self.album = ""
        self.artwork = nil
    }

    private func startObservingCurrentTrack(_ qp: QueuePlayer) {
        self.currentTrackTask = Task { [weak self] in
            guard let self else { return }
            for await track in qp.currentTrackChanges {
                if let track {
                    self.setCurrentTrack(track)
                } else if let item = await qp.queue.currentItem {
                    await self.applyStreamItem(item)
                } else {
                    self.clearNowPlayingDisplay()
                }
            }
        }
        // Observe queue changes to keep UI state (shuffle, repeat, stop-after-current) in sync.
        self.queueChangesTask = Task { [weak self] in
            guard let self else { return }
            let initialRepeat = await qp.queue.repeatMode
            let initialShuffle = await qp.queue.shuffleState
            let initialStopAfter = await qp.queue.stopAfterCurrent
            self.repeatMode = initialRepeat
            self.shuffleOn = initialShuffle != .off
            self.stopAfterCurrent = initialStopAfter

            for await change in await qp.queue.changes() {
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
                if remaining == nil { self.sleepTimerActiveMinutes = nil }
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
    func loadSubsonicArtwork(serverID: UUID, songID: String) async {
        guard let provider = self.subsonicCoverArtProvider else { return }
        do {
            guard let url = try await provider.coverArtURL(serverID: serverID, entityID: songID) else {
                return
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return }
            // Only apply if the same Subsonic song is still current.
            if let qp = self.engine as? QueuePlayer,
               let item = await qp.queue.currentItem,
               case let .subsonic(_, currentSongID) = item.playableSource,
               currentSongID == songID {
                self.artwork = image
            }
        } catch {
            self.log.warning(
                "nowplaying.subsonic.artwork.failed",
                ["songID": songID, "error": String(reflecting: error)]
            )
        }
    }

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

    /// Posts a `UNNotification` banner when a new track starts (if enabled and app is not frontmost).
    func postTrackChangeNotification(title: String, artist: String, artworkPath: String?) async {
        let settingOn = UserDefaults.standard.bool(forKey: "general.showNotifications")
        let appActive = NSApp?.isActive ?? true
        self.log.debug("notifications.attempt", ["settingOn": settingOn, "appActive": appActive, "title": title])
        guard settingOn else { return }
        guard !appActive else { return }

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
            let sourceURL = URL(fileURLWithPath: path)
            // UNNotificationAttachment moves the file into its own data store, which
            // fails when the source is inside the app sandbox container (daemon
            // cross-process access is denied). Copy to a world-readable temp location first.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(sourceURL.pathExtension)
            if (try? FileManager.default.copyItem(at: sourceURL, to: tempURL)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "artwork", url: tempURL) {
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
            self.log.info("notifications.posted", ["title": title])
        } catch {
            self.log.error("notifications.add.failed", ["error": String(reflecting: error)])
        }
    }
}
