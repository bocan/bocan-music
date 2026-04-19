import AppKit
import AudioEngine
import Foundation
import Observability
import Persistence
import Playback

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

    // MARK: - Internal

    private let engine: any Transport
    private let database: Database
    private var stateTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var currentTrack: Track?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(engine: any Transport, database: Database) {
        self.engine = engine
        self.database = database
        self.startObservingState()
    }

    // MARK: - Public API

    /// Set by the TracksView/AlbumsView when a track is selected and played.
    public func setCurrentTrack(_ track: Track) {
        self.currentTrack = track
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
            } else {
                try await self.engine.play()
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

    /// Cycles to the next repeat mode (off → all → one → off).
    public func cycleRepeat() async {
        guard let qp = engine as? QueuePlayer else { return }
        let next: RepeatMode = switch self.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        await qp.setRepeat(next)
        self.repeatMode = next
    }

    // MARK: - Private

    private func startObservingState() {
        self.stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.engine.state {
                guard !Task.isCancelled else { break }
                switch state {
                case .playing:
                    self.isPlaying = true
                    self.startPollingPosition()

                case .paused, .stopped, .idle, .ended:
                    self.isPlaying = false
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

    private func resolveMetadata(for track: Track) async {
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
                        let img = await ArtworkLoader.shared.image(at: path)
                        await MainActor.run { self.artwork = img }
                    }
                }
            }
        } catch {
            self.log.error("nowplaying.resolve.failed", ["error": String(reflecting: error)])
        }
    }
}
