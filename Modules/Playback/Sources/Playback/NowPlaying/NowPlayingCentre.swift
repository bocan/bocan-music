import AppKit
import Foundation
import MediaPlayer
import Observability
import Persistence

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

    private let log = AppLogger.make(.playback)

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Update the displayed track. Artwork is loaded from `coverArtPath` if available.
    public func update(
        track: Track,
        duration: TimeInterval,
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        self.getPosition = nil
        self.log.debug("nowplaying.clear")
    }

    // MARK: - Private

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
