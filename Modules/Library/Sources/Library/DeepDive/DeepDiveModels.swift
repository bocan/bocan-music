import Foundation

// MARK: - Deep Dive reports (#413)

/// A concise artist report assembled from MusicBrainz and Wikipedia.
/// Codable so `DeepDiveCache` can keep it on disk.
public struct ArtistReport: Codable, Sendable, Equatable {
    public struct Bio: Codable, Sendable, Equatable {
        public let extract: String
        public let pageURL: URL?
        public let thumbnailURL: URL?
        /// Always "Wikipedia, CC BY-SA 4.0"; the UI must show it.
        public let attribution: String
    }

    public struct Member: Codable, Sendable, Equatable {
        public let name: String
        public let mbid: String
        public let begin: String?
        public let end: String?
        public let ended: Bool
        /// Instruments / roles, e.g. ["guitar", "lead vocals"].
        public let roles: [String]
    }

    public struct Link: Codable, Sendable, Equatable {
        /// MusicBrainz relation type: "wikidata", "discogs", "official homepage", "bandcamp", ...
        public let type: String
        public let url: URL
    }

    public struct Release: Codable, Sendable, Equatable {
        public let title: String
        public let mbid: String
        /// "Album", "Single", "EP", "Broadcast", "Other", or nil.
        public let primaryType: String?
        public let secondaryTypes: [String]
        public let year: Int?
        /// True when an album in the library carries this release group, or
        /// matches the title under the same artist.
        public let owned: Bool
    }

    public let artistID: Int64
    public let mbid: String
    /// True when the MBID came from a name search rather than the tags.
    public let mbidGuessed: Bool
    public let name: String
    public let sortName: String?
    public let disambiguation: String?
    public let type: String?
    public let country: String?
    public let activeFrom: String?
    public let activeUntil: String?
    public let ended: Bool
    public let bio: Bio?
    public let members: [Member]
    public let links: [Link]
    public let discography: [Release]
    public let fetchedAt: Date
}

/// A concise recording report for a track.
public struct TrackReport: Codable, Sendable, Equatable {
    public struct Appearance: Codable, Sendable, Equatable {
        public let releaseTitle: String
        public let releaseMBID: String
        public let year: Int?
        public let country: String?
        public let status: String?
        public let primaryType: String?
        public let secondaryTypes: [String]
    }

    public let trackID: Int64
    public let recordingMBID: String
    public let title: String
    public let artistCredit: String
    /// Milliseconds.
    public let length: Int?
    public let isrcs: [String]
    public let firstReleaseYear: Int?
    /// Top genre tags by vote, most voted first.
    public let tags: [String]
    public let appearances: [Appearance]
    public let fetchedAt: Date
}

/// Errors surfaced to the Deep Dive UI.
public enum DeepDiveError: Error, Sendable, Equatable {
    /// The row has no MusicBrainz id and a name search found no confident match.
    case noIdentifier
    /// MusicBrainz or Wikipedia could not be reached and nothing is cached.
    case offline
    /// MusicBrainz asked us to slow down; try again shortly.
    case rateLimited
    case notFound
}
