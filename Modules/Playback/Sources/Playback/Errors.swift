import Foundation

/// All errors produced by the `Playback` module.
public enum PlaybackError: Error, Sendable, CustomStringConvertible {
    case noBookmark(trackID: Int64)
    case bookmarkResolutionFailed(trackID: Int64, underlying: Error)
    case trackNotFound(id: Int64)
    case queueEmpty
    case engineFailure(underlying: Error)
    case incompatibleFormat(reason: String)

    public var description: String {
        switch self {
        case let .noBookmark(id):
            "Track \(id) has no security-scoped bookmark; re-scan to create one."
        case let .bookmarkResolutionFailed(id, err):
            "Bookmark resolution failed for track \(id): \(err.localizedDescription)"
        case let .trackNotFound(id):
            "Track \(id) not found in the database."
        case .queueEmpty:
            "The playback queue is empty."
        case let .engineFailure(err):
            "Audio engine failure: \(err.localizedDescription)"
        case let .incompatibleFormat(reason):
            "Incompatible audio format for gapless playback: \(reason)"
        }
    }
}
