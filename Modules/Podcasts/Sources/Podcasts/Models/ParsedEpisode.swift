import Foundation

/// One episode entry from a parsed feed, normalized across RSS and Atom.
public struct ParsedEpisode: Sendable {
    public var guid: String
    public var title: String
    public var subtitle: String?
    public var descriptionHTML: String?
    public var audioURL: URL
    public var audioMIME: String?
    public var audioByteLength: Int64?
    public var duration: TimeInterval?
    public var publishedAt: Date?
    public var season: Int?
    public var episodeNumber: Int?
    public var episodeType: String?
    public var artworkURL: URL?
    public var chaptersURL: URL?
    public var transcriptURL: URL?
    public var link: URL?
    public var explicit: Bool

    public init(
        guid: String,
        title: String,
        subtitle: String? = nil,
        descriptionHTML: String? = nil,
        audioURL: URL,
        audioMIME: String? = nil,
        audioByteLength: Int64? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil,
        season: Int? = nil,
        episodeNumber: Int? = nil,
        episodeType: String? = nil,
        artworkURL: URL? = nil,
        chaptersURL: URL? = nil,
        transcriptURL: URL? = nil,
        link: URL? = nil,
        explicit: Bool = false
    ) {
        self.guid = guid
        self.title = title
        self.subtitle = subtitle
        self.descriptionHTML = descriptionHTML
        self.audioURL = audioURL
        self.audioMIME = audioMIME
        self.audioByteLength = audioByteLength
        self.duration = duration
        self.publishedAt = publishedAt
        self.season = season
        self.episodeNumber = episodeNumber
        self.episodeType = episodeType
        self.artworkURL = artworkURL
        self.chaptersURL = chaptersURL
        self.transcriptURL = transcriptURL
        self.link = link
        self.explicit = explicit
    }
}
