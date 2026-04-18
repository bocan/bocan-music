/// Playback lifecycle states emitted on the `Transport.state` stream.
///
/// Transitions follow the direction of the arrows. Duplicate consecutive
/// states are suppressed by `AudioEngine` before publishing.
///
/// ```
/// idle → loading → ready → playing → ended
///               ↘      ↕        ↘
///                failed   paused  stopped
/// ```
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case ended
    case failed(AudioEngineError)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready),
             (.playing, .playing), (.paused, .paused), (.stopped, .stopped),
             (.ended, .ended):
            true

        case let (.failed(l), .failed(r)):
            l.description == r.description

        default:
            false
        }
    }
}
