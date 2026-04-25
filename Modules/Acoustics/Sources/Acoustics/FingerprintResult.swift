/// A single identified candidate returned after an AcoustID + MusicBrainz lookup.
public struct IdentificationCandidate: Sendable, Identifiable {
    /// The AcoustID result identifier.
    public let id: String
    /// Match confidence in the range 0…1.
    public let score: Double
    /// MusicBrainz recording MBID, if one was associated with the AcoustID result.
    public let mbRecordingID: String?
    public let title: String
    public let artist: String
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let genre: String?
    public let label: String?

    public init(
        id: String,
        score: Double,
        mbRecordingID: String?,
        title: String,
        artist: String,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.score = score
        self.mbRecordingID = mbRecordingID
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.label = label
    }
}

// MARK: - AcoustID response models

struct AcoustIDResponse: Decodable {
    let status: String
    let results: [AcoustIDResult]
}

public struct AcoustIDResult: Decodable, Sendable {
    public let id: String
    public let score: Double
    public let recordings: [AcoustIDRecording]?
}

public struct AcoustIDRecording: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let duration: Double?
    public let artists: [AcoustIDArtist]?
    public let releases: [AcoustIDRelease]?
}

public struct AcoustIDArtist: Decodable, Sendable {
    public let id: String
    public let name: String
}

public struct AcoustIDRelease: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let date: AcoustIDDate?
    public let mediums: [AcoustIDMedium]?
}

public struct AcoustIDDate: Decodable, Sendable {
    public let year: Int?
    public let month: Int?
    public let day: Int?
}

public struct AcoustIDMedium: Decodable, Sendable {
    public let position: Int?
    public let trackCount: Int?
    public let tracks: [AcoustIDTrackPosition]?

    enum CodingKeys: String, CodingKey {
        case position
        case trackCount = "track_count"
        case tracks
    }
}

public struct AcoustIDTrackPosition: Decodable, Sendable {
    public let position: Int?
    public let title: String?
}

// MARK: - fpcalc JSON output

struct FpcalcOutput: Decodable {
    let fingerprint: String
    let duration: Double
}
