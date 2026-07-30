import AppKit
import Foundation
import MediaPlayer
import Observability
import Persistence

// MARK: - ArtworkPayload

private struct ArtworkPayload {
    let data: Data
    let boundsSize: CGSize
}

// MARK: - NowPlayingCentre

/// Updates `MPNowPlayingInfoCenter` and manages the 1 Hz position ticker.
///
/// Must be created and used on the `@MainActor` since `MPNowPlayingInfoCenter`
/// is a main-thread singleton.
@MainActor
public final class NowPlayingCentre {
    // MARK: - State

    private var positionTimer: Task<Void, Never>?
    private var isPlaying = false
    private var getPosition: (@Sendable () async -> TimeInterval)?

    /// Monotonic token guarding against a late-arriving artwork load from a
    /// superseded track overwriting the now-playing info of the current one.
    /// Bumped on every `update(track:…)` / `clear()`; in-flight loads compare
    /// their captured token against this and bail if they've been superseded.
    private var artworkToken: UInt64 = 0

    private let log = AppLogger.make(.playback)

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Update the displayed track. Artwork is loaded asynchronously from
    /// `coverArtPath` (when non-`nil`) and applied to `nowPlayingInfo` once
    /// ready; until then the system shows a generic audio glyph.
    public func update(
        track: Track,
        duration: TimeInterval,
        coverArtPath: String? = nil,
        positionProvider: @Sendable @escaping () async -> TimeInterval
    ) {
        self.getPosition = positionProvider

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.title ?? track.fileURL.components(separatedBy: "/").last
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if self.isPlaying { self.startPositionTimer() }
        self.log.debug("nowplaying.update", ["title": track.title ?? "unknown"])

        self.loadArtwork(path: coverArtPath)
    }

    /// Update the displayed item for a podcast episode. Maps the episode title
    /// to the title slot and the show name to the artist + podcast-title slots
    /// (per the Phase 21 brief: the artist slot carries the show name).
    ///
    /// Note: `MPNowPlayingInfoMediaType` has only `.none` / `.audio` / `.video`
    /// (there is no `.podcast` member in the MediaPlayer framework, contrary to
    /// the phase 21-5 spec). The podcast nature is conveyed to the system via
    /// `MPMediaItemPropertyPodcastTitle`; the media type stays `.audio`, which
    /// is the only correct audio value.
    public func updatePodcast(
        title: String,
        showName: String,
        duration: TimeInterval,
        positionProvider: @Sendable @escaping () async -> TimeInterval
    ) {
        self.getPosition = positionProvider

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = showName
        info[MPMediaItemPropertyPodcastTitle] = showName
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if self.isPlaying { self.startPositionTimer() }
        self.log.debug("nowplaying.update.podcast", ["title": title, "show": showName])
    }

    /// Called when playback state changes.
    public func setPlaying(_ playing: Bool) {
        self.isPlaying = playing
        if playing {
            self.startPositionTimer()
            MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        } else {
            self.stopPositionTimer()
            MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        }
    }

    /// Clear the now-playing info (e.g. when queue is exhausted).
    public func clear() {
        self.stopPositionTimer()
        self.artworkToken &+= 1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        self.getPosition = nil
        self.log.debug("nowplaying.clear")
    }

    // MARK: - Private

    /// Loads artwork from `path` off the main thread and applies it to
    /// `nowPlayingInfo` on completion. A monotonic token guards against a
    /// late-arriving image from a superseded track overwriting the current
    /// track's now-playing info (e.g. when skipping quickly between tracks).
    private func loadArtwork(path: String?) {
        self.artworkToken &+= 1
        let token = self.artworkToken
        guard let path else { return }

        Task { [weak self] in
            // Keep file I/O and image inspection off the main thread. Only
            // Sendable value types cross back to the main actor.
            let payload = await Task.detached(priority: .utility) { () -> ArtworkPayload? in
                guard let data = FileManager.default.contents(atPath: path),
                      !data.isEmpty,
                      let image = NSImage(data: data) else {
                    return nil
                }
                return ArtworkPayload(data: data, boundsSize: image.size)
            }.value

            guard let self else { return }
            // Bail if a newer `update` / `clear` superseded this load.
            guard self.artworkToken == token else { return }
            guard let payload else {
                self.log.debug("nowplaying.artwork.load_failed", ["path": path])
                return
            }
            // No suspension point between the token check and the write, so a
            // concurrent `update` cannot slip in and clobber our mutation.
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: payload.boundsSize,
                requestHandler: Self.artworkRequestHandler(data: payload.data)
            )
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            self.log.debug("nowplaying.artwork.set", ["path": path])
        }
    }

    /// MediaPlayer invokes this callback on its private access queue. Building
    /// it inline in a `@MainActor` method makes Swift 6 enforce main-actor
    /// isolation at runtime, so construct an explicitly Sendable callback that
    /// captures only image data and decodes on the requesting queue.
    nonisolated static func artworkRequestHandler(
        data: Data
    ) -> @Sendable (CGSize) -> NSImage {
        { requestedSize in
            guard let image = NSImage(data: data) else {
                let fallbackSize = requestedSize.width > 0 && requestedSize.height > 0
                    ? requestedSize
                    : CGSize(width: 1, height: 1)
                return NSImage(size: fallbackSize)
            }
            return image
        }
    }

    private func startPositionTimer() {
        self.stopPositionTimer()
        guard let provider = getPosition else { return }
        self.positionTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let pos = await provider()
                self?.updatePosition(pos)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPositionTimer() {
        self.positionTimer?.cancel()
        self.positionTimer = nil
    }

    private func updatePosition(_ position: TimeInterval) {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
    }
}
