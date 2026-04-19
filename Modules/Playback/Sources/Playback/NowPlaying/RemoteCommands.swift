import Foundation
import MediaPlayer
import Observability

// MARK: - RemoteCommands

/// Registers and responds to `MPRemoteCommandCenter` hardware / Siri / lock-screen events.
///
/// Must be created on the `@MainActor` because `MPRemoteCommandCenter.shared()` is
/// a main-thread singleton.
@MainActor
public final class RemoteCommands {
    // MARK: - Handlers (set by QueuePlayer after init)

    public var onPlay: (@Sendable () async -> Void)?
    public var onPause: (@Sendable () async -> Void)?
    public var onTogglePlayPause: (@Sendable () async -> Void)?
    public var onNextTrack: (@Sendable () async -> Void)?
    public var onPreviousTrack: (@Sendable () async -> Void)?
    public var onSeek: (@Sendable (TimeInterval) async -> Void)?

    private let log = AppLogger.make(.playback)
    private var isRegistered = false

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Bind all relevant commands. Idempotent — safe to call multiple times.
    public func register() {
        guard !self.isRegistered else { return }
        self.isRegistered = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.onPlay?() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.onPause?() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.onTogglePlayPause?() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.onNextTrack?() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.onPreviousTrack?() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let pos = posEvent.positionTime
            Task { await self.onSeek?(pos) }
            return .success
        }

        // Disable commands we don't implement.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.ratingCommand.isEnabled = false

        self.log.debug("remotecommands.registered")
    }

    /// Remove all command targets and disable commands.
    public func unregister() {
        guard self.isRegistered else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        self.isRegistered = false
        self.log.debug("remotecommands.unregistered")
    }
}
