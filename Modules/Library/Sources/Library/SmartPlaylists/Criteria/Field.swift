/// The data type category of a `Field`, used to determine valid comparators.
public enum DataType: Sendable, Hashable {
    case text
    case numeric
    case duration
    case date
    case bool
    case enumeration([String]) // finite set of allowed strings
    case membership
}

/// Every track attribute that can appear in a smart-playlist rule.
///
/// Each case maps to a SQLite column (plus optional JOIN). Use
/// `FieldDefinitions` to resolve the SQL expression and allowed comparators.
public enum Field: Sendable, Codable, Hashable, CaseIterable {
    // MARK: - Text fields

    case title
    case artist
    case albumArtist
    case album
    case genre
    case composer
    case comment

    // MARK: - Numeric fields

    case year
    case trackNumber
    case discNumber
    case playCount
    case skipCount
    /// 0–100 integer rating.
    case rating
    case bpm
    case bitrate
    case sampleRate
    case bitDepth

    // MARK: - Duration

    case duration

    // MARK: - Date fields

    case addedAt
    case lastPlayedAt

    // MARK: - Boolean fields

    case loved
    case excludedFromShuffle
    case isLossless
    case hasCoverArt
    case hasLyrics
    case hasMusicBrainzReleaseID

    // MARK: - Enum fields

    case fileFormat

    // MARK: - Membership fields

    case inPlaylist
    case notInPlaylist
    case pathUnder

    /// Forward-compatible value loaded from JSON written by a newer app.
    case unknown(String)
}

// MARK: - Raw representable

public extension Field {
    init(rawValue: String) {
        switch rawValue {
        case "title": self = .title
        case "artist": self = .artist
        case "albumArtist": self = .albumArtist
        case "album": self = .album
        case "genre": self = .genre
        case "composer": self = .composer
        case "comment": self = .comment
        case "year": self = .year
        case "trackNumber": self = .trackNumber
        case "discNumber": self = .discNumber
        case "playCount": self = .playCount
        case "skipCount": self = .skipCount
        case "rating": self = .rating
        case "bpm": self = .bpm
        case "bitrate": self = .bitrate
        case "sampleRate": self = .sampleRate
        case "bitDepth": self = .bitDepth
        case "duration": self = .duration
        case "addedAt": self = .addedAt
        case "lastPlayedAt": self = .lastPlayedAt
        case "loved": self = .loved
        case "excludedFromShuffle": self = .excludedFromShuffle
        case "isLossless": self = .isLossless
        case "hasCoverArt": self = .hasCoverArt
        case "hasLyrics": self = .hasLyrics
        case "hasMusicBrainzReleaseID": self = .hasMusicBrainzReleaseID
        case "fileFormat": self = .fileFormat
        case "inPlaylist": self = .inPlaylist
        case "notInPlaylist": self = .notInPlaylist
        case "pathUnder": self = .pathUnder
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .title: "title"
        case .artist: "artist"
        case .albumArtist: "albumArtist"
        case .album: "album"
        case .genre: "genre"
        case .composer: "composer"
        case .comment: "comment"
        case .year: "year"
        case .trackNumber: "trackNumber"
        case .discNumber: "discNumber"
        case .playCount: "playCount"
        case .skipCount: "skipCount"
        case .rating: "rating"
        case .bpm: "bpm"
        case .bitrate: "bitrate"
        case .sampleRate: "sampleRate"
        case .bitDepth: "bitDepth"
        case .duration: "duration"
        case .addedAt: "addedAt"
        case .lastPlayedAt: "lastPlayedAt"
        case .loved: "loved"
        case .excludedFromShuffle: "excludedFromShuffle"
        case .isLossless: "isLossless"
        case .hasCoverArt: "hasCoverArt"
        case .hasLyrics: "hasLyrics"
        case .hasMusicBrainzReleaseID: "hasMusicBrainzReleaseID"
        case .fileFormat: "fileFormat"
        case .inPlaylist: "inPlaylist"
        case .notInPlaylist: "notInPlaylist"
        case .pathUnder: "pathUnder"
        case let .unknown(raw): raw
        }
    }
}

// MARK: - Codable

public extension Field {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - CaseIterable

public extension Field {
    static var allCases: [Field] {
        [
            .title,
            .artist,
            .albumArtist,
            .album,
            .genre,
            .composer,
            .comment,
            .year,
            .trackNumber,
            .discNumber,
            .playCount,
            .skipCount,
            .rating,
            .bpm,
            .bitrate,
            .sampleRate,
            .bitDepth,
            .duration,
            .addedAt,
            .lastPlayedAt,
            .loved,
            .excludedFromShuffle,
            .isLossless,
            .hasCoverArt,
            .hasLyrics,
            .hasMusicBrainzReleaseID,
            .fileFormat,
            .inPlaylist,
            .notInPlaylist,
            .pathUnder,
        ]
    }
}
