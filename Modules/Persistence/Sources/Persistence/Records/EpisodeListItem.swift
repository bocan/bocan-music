import Foundation

// MARK: - EpisodePlayState

/// Playback progress state for a podcast episode, stored as a TEXT rawValue in `podcast_episode_state`.
public enum EpisodePlayState: String, Sendable, Codable, Equatable, CaseIterable {
    case unplayed
    case inProgress
    case played
}

// MARK: - EpisodeDownloadState

/// Download state for a podcast episode enclosure, stored as a TEXT rawValue in `podcast_episode_state`.
public enum EpisodeDownloadState: String, Sendable, Codable, Equatable, CaseIterable {
    // swiftlint:disable:next discouraged_none_name
    case none
    case queued
    case downloading
    case downloaded
    case failed
}

// MARK: - EpisodeListItem

/// The joined read model the episode list UI renders.
///
/// One item = one `podcast_episodes` content row LEFT JOIN its optional `podcast_episode_state`
/// row. `state == nil` means the episode is unplayed at position 0 with no download.
/// This is assembled by `EpisodeRepository` and never written directly.
public struct EpisodeListItem: Sendable, Hashable, Identifiable {
    public var episode: PodcastEpisode
    public var state: PodcastEpisodeState?

    /// Stable identity from the episode rowid. Safe to use as a SwiftUI list id.
    public var id: Int64 {
        self.episode.id ?? 0
    }

    public init(episode: PodcastEpisode, state: PodcastEpisodeState?) {
        self.episode = episode
        self.state = state
    }
}
