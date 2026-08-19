import Foundation

// MARK: - ContinueListeningItem

/// One card in the Podcasts home view's Continue Listening rail (ADR-054): an
/// episode the user has started but not finished, joined to enough content to
/// render and resume without a re-fetch. Produced by
/// `EpisodeStateRepository.continueListening(limit:)`; lives in Persistence
/// because UI consumes Persistence types and must not import Podcasts.
public struct ContinueListeningItem: Sendable, Hashable, Identifiable {
    public var podcastID: Int64
    public var guid: String
    /// Show title (`podcasts.title`). Feed content, rendered verbatim.
    public var showTitle: String
    /// Episode title (`podcast_episodes.title`). Feed content, rendered verbatim.
    public var episodeTitle: String
    /// Episode art when present, else show art (COALESCEd in SQL).
    public var artworkPath: String?
    /// Remote fallback matching `artworkPath`'s precedence.
    public var artworkURL: String?
    /// Resume point in seconds. Drives the card's progress bar only; the
    /// resolver seeks to the saved position itself on play (ADR-042).
    public var playPosition: Double
    /// Episode duration in seconds; nil hides the progress bar.
    public var duration: Double?
    /// Sort key (epoch seconds); never nil for in-progress rows.
    public var lastPlayedAt: Double

    public var id: String {
        "\(self.podcastID):\(self.guid)"
    }

    public init(
        podcastID: Int64,
        guid: String,
        showTitle: String,
        episodeTitle: String,
        artworkPath: String?,
        artworkURL: String?,
        playPosition: Double,
        duration: Double?,
        lastPlayedAt: Double
    ) {
        self.podcastID = podcastID
        self.guid = guid
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
        self.artworkPath = artworkPath
        self.artworkURL = artworkURL
        self.playPosition = playPosition
        self.duration = duration
        self.lastPlayedAt = lastPlayedAt
    }
}
