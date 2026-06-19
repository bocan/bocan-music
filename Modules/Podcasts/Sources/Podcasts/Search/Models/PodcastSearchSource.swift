import Foundation

/// Which search index(es) a ``PodcastSearchResult`` came from.
public enum PodcastSearchSource: String, Sendable, Codable, CaseIterable, Hashable {
    case podcastIndex
    case itunes
}
