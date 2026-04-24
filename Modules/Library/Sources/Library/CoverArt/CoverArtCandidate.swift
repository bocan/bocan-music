import Foundation

// MARK: - CoverArtCandidate

/// A single cover-art search result from MusicBrainz / Cover Art Archive.
public struct CoverArtCandidate: Sendable, Hashable, Identifiable {
    /// Unique identifier (MBID or archive identifier).
    public let id: String

    /// MusicBrainz release-group MBID, if available.
    public let releaseGroupID: String?

    /// MusicBrainz release MBID, if available.
    public let releaseID: String?

    /// Release title.
    public let title: String

    /// Artist name.
    public let artist: String

    /// Release year.
    public let year: Int?

    /// URL to the 500 px thumbnail.
    public let thumbnailURL: URL

    /// URL to the full-resolution image.
    public let fullURL: URL

    /// Image dimensions if known.
    public let dimensions: CGSize?

    /// Where this candidate originated.
    public let source: Source

    public enum Source: String, Sendable, Codable {
        case musicbrainz
        case coverArtArchive
    }

    public init(
        id: String,
        releaseGroupID: String? = nil,
        releaseID: String? = nil,
        title: String,
        artist: String,
        year: Int? = nil,
        thumbnailURL: URL,
        fullURL: URL,
        dimensions: CGSize? = nil,
        source: Source
    ) {
        self.id = id
        self.releaseGroupID = releaseGroupID
        self.releaseID = releaseID
        self.title = title
        self.artist = artist
        self.year = year
        self.thumbnailURL = thumbnailURL
        self.fullURL = fullURL
        self.dimensions = dimensions
        self.source = source
    }
}
