import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Remote commands

extension QueuePlayer {
    // MARK: Remote commands

    /// A transport command that arrived from outside the app: the lock screen,
    /// a media key, headphone controls, Siri or the Control Centre widget.
    enum RemoteCommand: Sendable {
        case play
        case togglePlayPause
        case next
        case previous
        case seek(TimeInterval, label: String)

        /// The name logged when the command fails.
        var label: String {
            switch self {
            case .play:
                "play"

            case .togglePlayPause:
                "togglePlayPause"

            case .next:
                "nextTrack"

            case .previous:
                "previousTrack"

            case let .seek(_, label):
                label
            }
        }
    }

    /// Runs a remote transport command, reporting a failure the way the in-app
    /// buttons do.
    ///
    /// Those buttons surface their error because the view model that called
    /// them catches it; a media key has no such caller, so these dropped the
    /// error entirely and the key looked dead with nothing in the log (#482).
    /// A failure is logged with the command name and pushed onto the state
    /// stream, where `NowPlayingViewModel` already turns `.failed` into the
    /// user's "playback stopped" toast.
    func runRemote(_ command: RemoteCommand) async {
        do {
            switch command {
            case .play:
                try await self.play()

            case .togglePlayPause:
                try await self.performTogglePlayPause()

            case .next:
                try await self.next()

            case .previous:
                try await self.previous()

            case let .seek(time, _):
                try await self.seek(to: time)
            }
        } catch is CancellationError {
            return
        } catch {
            self.log.error("remote.command.failed", [
                "command": command.label,
                "error": String(reflecting: error),
            ])
            self.stateContinuation?.yield(.failed(Self.remoteFailure(error)))
        }
    }

    /// The engine's own error where there is one, so the reason survives to the
    /// state stream; anything else is wrapped the way the skip path wraps it.
    private static func remoteFailure(_ error: any Error) -> AudioEngineError {
        error as? AudioEngineError ?? .decoderFailure(codec: "unknown", underlying: error)
    }

    private func performTogglePlayPause() async throws {
        if case .playing = self.lastEmittedState {
            await self.pause()
        } else {
            try await self.play()
        }
    }

    /// Switches the lock-screen / headphone remote commands to podcast skip-interval mode.
    /// Call from `NowPlayingViewModel` when a podcast episode becomes the current item.
    public func configureRemoteCommandsForPodcast(backInterval: TimeInterval, forwardInterval: TimeInterval) async {
        let commands = self.remoteCommands
        await MainActor.run {
            commands?.configureForPodcast(backInterval: backInterval, forwardInterval: forwardInterval)
        }
    }

    /// Restores the lock-screen / headphone remote commands to music (prev/next) mode.
    /// Call from `NowPlayingViewModel` when a non-podcast item becomes current.
    public func configureRemoteCommandsForMusic() async {
        let commands = self.remoteCommands
        await MainActor.run { commands?.configureForMusic() }
    }
}
