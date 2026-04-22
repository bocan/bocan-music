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
public enum Field: String, Sendable, Codable, Hashable, CaseIterable {
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
    case hasMusicBrainzReleaseID

    // MARK: - Enum fields

    case fileFormat

    // MARK: - Membership fields

    case inPlaylist
    case notInPlaylist
    case pathUnder
}
