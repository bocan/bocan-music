import GRDB

// MARK: - SQLColumnRef

/// A resolved column expression, including any JOIN clause it requires.
public struct SQLColumnRef: Sendable {
    /// The bare column expression used in WHERE / ORDER BY.
    /// E.g. `"tracks.title"`, `"artists.name"`.
    public let expression: String

    /// Optional JOIN clause to include in the FROM list (e.g. for artist name).
    public let join: Join?

    public init(expression: String, join: Join? = nil) {
        self.expression = expression
        self.join = join
    }
}

// MARK: - Join

/// A SQL JOIN to add to a smart-playlist query.
public struct Join: Sendable, Hashable {
    public let clause: String

    public init(_ clause: String) {
        self.clause = clause
    }
}

// MARK: - FieldDefinition

/// Static mapping from a `Field` to its SQL column reference, data type,
/// and the set of comparators the UI should offer.
public struct FieldDefinition: Sendable {
    public let dataType: DataType
    public let allowedComparators: [Comparator]
    public let columnRef: SQLColumnRef
}

// MARK: - FieldDefinitions

/// Registry of all field → SQL mappings.
public enum FieldDefinitions {
    // MARK: - Lookup

    /// Returns the definition for `field`.
    public static func definition(for field: Field) -> FieldDefinition {
        self.table[field]! // table is exhaustive
    }

    // MARK: - Private table

    // swiftlint:disable:next closure_body_length
    private static let table: [Field: FieldDefinition] = {
        var t: [Field: FieldDefinition] = [:]

        // ── Text ─────────────────────────────────────────────────────────────
        t[.title] = .init(dataType: .text, allowedComparators: .text, columnRef: .init(expression: "tracks.title"))
        t[.album] = .init(
            dataType: .text,
            allowedComparators: .text,
            columnRef: .init(expression: "albums.title", join: Join("LEFT JOIN albums ON albums.id = tracks.album_id"))
        )
        t[.artist] = .init(
            dataType: .text,
            allowedComparators: .text,
            columnRef: .init(expression: "artists.name", join: Join("LEFT JOIN artists ON artists.id = tracks.artist_id"))
        )
        t[.albumArtist] = .init(
            dataType: .text,
            allowedComparators: .text,
            columnRef: .init(
                expression: "album_artists.name",
                join: Join("LEFT JOIN artists AS album_artists ON album_artists.id = tracks.album_artist_id")
            )
        )
        t[.genre] = .init(dataType: .text, allowedComparators: .text, columnRef: .init(expression: "tracks.genre"))
        t[.composer] = .init(dataType: .text, allowedComparators: .text, columnRef: .init(expression: "tracks.composer"))
        t[.comment] = .init(dataType: .text, allowedComparators: .text, columnRef: .init(expression: "tracks.comment"))

        // ── Numeric ──────────────────────────────────────────────────────────
        t[.year] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.year"))
        t[.trackNumber] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.track_number"))
        t[.discNumber] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.disc_number"))
        t[.playCount] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.play_count"))
        t[.skipCount] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.skip_count"))
        t[.rating] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.rating"))
        t[.bpm] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.bpm"))
        t[.bitrate] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.bitrate"))
        t[.sampleRate] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.sample_rate"))
        t[.bitDepth] = .init(dataType: .numeric, allowedComparators: .numeric, columnRef: .init(expression: "tracks.bit_depth"))

        // ── Duration ─────────────────────────────────────────────────────────
        t[.duration] = .init(dataType: .duration, allowedComparators: .duration, columnRef: .init(expression: "tracks.duration"))

        // ── Date ─────────────────────────────────────────────────────────────
        t[.addedAt] = .init(dataType: .date, allowedComparators: .date, columnRef: .init(expression: "tracks.added_at"))
        t[.lastPlayedAt] = .init(dataType: .date, allowedComparators: .date, columnRef: .init(expression: "tracks.last_played_at"))

        // ── Boolean ──────────────────────────────────────────────────────────
        t[.loved] = .init(dataType: .bool, allowedComparators: .bool, columnRef: .init(expression: "tracks.loved"))
        t[.excludedFromShuffle] = .init(
            dataType: .bool,
            allowedComparators: .bool,
            columnRef: .init(expression: "tracks.excluded_from_shuffle")
        )
        t[.isLossless] = .init(dataType: .bool, allowedComparators: .bool, columnRef: .init(expression: "tracks.is_lossless"))
        t[.hasCoverArt] = .init(dataType: .bool, allowedComparators: .bool, columnRef: .init(expression: "tracks.cover_art_hash"))
        t[.hasMusicBrainzReleaseID] = .init(
            dataType: .bool,
            allowedComparators: .bool,
            columnRef: .init(expression: "tracks.musicbrainz_release_id")
        )

        // ── Enum ─────────────────────────────────────────────────────────────
        let formats = ["flac", "mp3", "aac", "alac", "ogg", "opus", "wav", "aiff", "m4a", "wv", "ape"]
        t[.fileFormat] = .init(
            dataType: .enumeration(formats),
            allowedComparators: [.is, .isNot],
            columnRef: .init(expression: "tracks.file_format")
        )

        // ── Membership ───────────────────────────────────────────────────────
        t[.inPlaylist] = .init(
            dataType: .membership,
            allowedComparators: [.memberOf],
            columnRef: .init(
                expression: "sp_pt.track_id",
                join: nil // join generated dynamically with playlist ID
            )
        )
        t[.notInPlaylist] = .init(
            dataType: .membership,
            allowedComparators: [.notMemberOf],
            columnRef: .init(expression: "tracks.id")
        )
        t[.pathUnder] = .init(
            dataType: .membership,
            allowedComparators: [.pathUnder],
            columnRef: .init(expression: "tracks.file_url")
        )

        return t
    }()
}

// MARK: - Comparator sets

private extension [Comparator] {
    static let text: [Comparator] = [
        .is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .matchesRegex, .isEmpty, .isNotEmpty,
    ]

    static let numeric: [Comparator] = [
        .equalTo, .notEqualTo, .lessThan, .greaterThan, .lessThanOrEqual, .greaterThanOrEqual, .between, .isNull, .isNotNull,
    ]

    static let duration: [Comparator] = numeric

    static let date: [Comparator] = [
        .beforeDate, .afterDate, .onDate, .between, .inLastDays, .inLastMonths, .isNull, .isNotNull,
    ]

    static let bool: [Comparator] = [.isTrue, .isFalse]
}
