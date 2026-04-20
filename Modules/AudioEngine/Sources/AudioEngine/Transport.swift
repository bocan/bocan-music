import Foundation

/// Public transport interface for controlling audio playback.
///
/// Conformers must be `Sendable` (e.g. actors or `@unchecked Sendable` with
/// appropriate synchronisation). All mutating operations are `async` so callers
/// can `await` completion/confirmation without blocking.
public protocol Transport: Sendable {
    /// Current playback position in seconds.
    var currentTime: TimeInterval { get async }

    /// Duration of the loaded file in seconds. 0 if no file is loaded.
    var duration: TimeInterval { get async }

    /// Asynchronous stream of `PlaybackState` transitions.
    /// Duplicate consecutive states are suppressed.
    var state: AsyncStream<PlaybackState> { get }

    /// Load a local audio file. Transitions state to `.loading` then `.ready`.
    func load(_ url: URL) async throws

    /// Start or resume playback. State transitions to `.playing`.
    func play() async throws

    /// Pause playback. State transitions to `.paused`.
    func pause() async

    /// Stop playback and unload the current file. State transitions to `.stopped`.
    func stop() async

    /// Seek to an approximate time within the loaded file.
    /// Throws `AudioEngineError.seekOutOfRange` if `time` exceeds `duration`.
    func seek(to time: TimeInterval) async throws

    /// Set the playback volume in the range [0, 1].
    func setVolume(_ volume: Float) async
}
