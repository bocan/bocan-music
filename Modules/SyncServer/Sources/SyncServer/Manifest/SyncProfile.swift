import Foundation

/// What a phone is allowed to see (Mac-owned). Persisted as an opaque JSON blob
/// via `SyncProfileRepository`; the default when unset is everything, podcasts
/// included.
public enum SyncProfile: Sendable, Codable, Equatable {
    case everything(includePodcasts: Bool)
    case selected(playlistIds: [Int64], includePodcasts: Bool)

    public static let `default` = SyncProfile.everything(includePodcasts: true)

    /// Whether podcasts are part of the sync set.
    public var includesPodcasts: Bool {
        switch self {
        case let .everything(includePodcasts):
            includePodcasts
        case let .selected(_, includePodcasts):
            includePodcasts
        }
    }
}
