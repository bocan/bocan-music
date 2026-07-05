/// A single identified candidate returned after an AcoustID + MusicBrainz lookup.
///
/// Top-level fields (`album`, `year`, `trackNumber`, …) are derived from the default
/// (best-ranked) release so callers that never look at `releases` see sensible values.
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
    /// ISRCs registered for the recording; apply the first when tagging.
    public let isrcs: [String]
    /// Every release MusicBrainz returned for the recording, best-ranked first
    /// (Official → earliest date → plain album over compilation). Empty when the
    /// candidate was built from AcoustID data alone.
    public let releases: [ReleaseOption]

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
        label: String? = nil,
        isrcs: [String] = [],
        releases: [ReleaseOption] = []
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
        self.isrcs = isrcs
        self.releases = releases
    }
}

/// One concrete release of an identified recording — the unit the user picks in the
/// release chooser (original album vs. compilation vs. remaster, territory, format).
public struct ReleaseOption: Sendable, Identifiable, Hashable {
    /// MusicBrainz release MBID.
    public let id: String
    public let title: String
    /// Full partial-ISO date string as MusicBrainz stores it ("1969-09-26" or "1969").
    public let date: String?
    public let year: Int?
    /// ISO 3166 country code.
    public let country: String?
    /// "Official", "Promotion", "Bootleg", …
    public let status: String?
    /// Display-only; nil from recording lookups (see `MusicBrainzClient.fetchRecording`).
    public let label: String?
    /// Display-only; nil from recording lookups.
    public let catalogNumber: String?
    public let albumArtist: String?
    public let albumArtistMBID: String?
    public let releaseGroupID: String?
    /// This recording's position within the release.
    public let trackNumber: Int?
    public let discNumber: Int?
    public let trackTotal: Int?
    /// Total discs. Not derivable from recording lookups (media is filtered to the
    /// matching medium), so nil today; kept for a future release-endpoint fetch.
    public let discTotal: Int?
    /// "CD", "12\" Vinyl", … display-only context for the picker.
    public let mediaFormat: String?

    public init(
        id: String,
        title: String,
        date: String? = nil,
        year: Int? = nil,
        country: String? = nil,
        status: String? = nil,
        label: String? = nil,
        catalogNumber: String? = nil,
        albumArtist: String? = nil,
        albumArtistMBID: String? = nil,
        releaseGroupID: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        trackTotal: Int? = nil,
        discTotal: Int? = nil,
        mediaFormat: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.year = year
        self.country = country
        self.status = status
        self.label = label
        self.catalogNumber = catalogNumber
        self.albumArtist = albumArtist
        self.albumArtistMBID = albumArtistMBID
        self.releaseGroupID = releaseGroupID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.trackTotal = trackTotal
        self.discTotal = discTotal
        self.mediaFormat = mediaFormat
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
