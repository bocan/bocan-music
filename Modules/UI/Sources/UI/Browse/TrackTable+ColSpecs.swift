import AppKit

// MARK: - Column spec

extension TrackTable {
    /// Describes a single table column's identity, sizing, and sort binding.
    struct ColSpec {
        /// The `NSUserInterfaceItemIdentifier` used for the column.
        let id: NSUserInterfaceItemIdentifier
        /// The localised header title.
        let title: String
        /// Minimum column width in points.
        let minWidth: CGFloat
        /// Default column width in points.
        let idealWidth: CGFloat
        /// Maximum column width in points.
        let maxWidth: CGFloat
        /// The sort descriptor key string, or `nil` if not sortable.
        let sortKey: String?
        /// Whether the column starts hidden.
        let hidden: Bool
    }

    /// All columns in display order.  Visibility can be toggled via the header menu.
    static let columnSpecs: [ColSpec] = [
        ColSpec(
            id: .albumArt,
            title: "Art",
            minWidth: 18,
            idealWidth: 32,
            maxWidth: 44,
            sortKey: nil,
            hidden: false
        ),
        ColSpec(
            id: .databaseID,
            title: "ID",
            minWidth: 36,
            idealWidth: 52,
            maxWidth: 72,
            sortKey: "databaseID",
            hidden: false
        ),
        ColSpec(
            id: .title,
            title: "Title",
            minWidth: 140,
            idealWidth: 220,
            maxWidth: 2000,
            sortKey: "title",
            hidden: false
        ),
        ColSpec(
            id: .artist,
            title: "Artist",
            minWidth: 100,
            idealWidth: 160,
            maxWidth: 2000,
            sortKey: "artistName",
            hidden: false
        ),
        ColSpec(
            id: .album,
            title: "Album",
            minWidth: 100,
            idealWidth: 160,
            maxWidth: 2000,
            sortKey: "albumName",
            hidden: false
        ),
        ColSpec(
            id: .year,
            title: "Year",
            minWidth: 48,
            idealWidth: 72,
            maxWidth: 120,
            sortKey: "yearText",
            hidden: false
        ),
        ColSpec(
            id: .genre,
            title: "Genre",
            minWidth: 80,
            idealWidth: 120,
            maxWidth: 2000,
            sortKey: "genre",
            hidden: false
        ),
        ColSpec(
            id: .duration,
            title: "Length",
            minWidth: 48,
            idealWidth: 60,
            maxWidth: 72,
            sortKey: "duration",
            hidden: false
        ),
        ColSpec(
            id: .trackNumber,
            title: "Track",
            minWidth: 28,
            idealWidth: 40,
            maxWidth: 56,
            sortKey: "trackNumber",
            hidden: false
        ),
        ColSpec(
            id: .trackTotal,
            title: "Of",
            minWidth: 28,
            idealWidth: 40,
            maxWidth: 56,
            sortKey: "trackTotal",
            hidden: false
        ),
        ColSpec(
            id: .discNumber,
            title: "Disc",
            minWidth: 28,
            idealWidth: 40,
            maxWidth: 56,
            sortKey: "discNumber",
            hidden: true
        ),
        ColSpec(
            id: .discTotal,
            title: "Discs",
            minWidth: 28,
            idealWidth: 40,
            maxWidth: 56,
            sortKey: "discTotal",
            hidden: true
        ),
        ColSpec(
            id: .playCount,
            title: "Plays",
            minWidth: 36,
            idealWidth: 48,
            maxWidth: 56,
            sortKey: "playCount",
            hidden: false
        ),
        ColSpec(
            id: .rating,
            title: "Rating",
            minWidth: 52,
            idealWidth: 64,
            maxWidth: 72,
            sortKey: "rating",
            hidden: false
        ),
        ColSpec(
            id: .loved,
            title: "\u{2665}",
            minWidth: 24,
            idealWidth: 32,
            maxWidth: 40,
            sortKey: "lovedSortKey",
            hidden: false
        ),
        ColSpec(
            id: .addedAt,
            title: "Date Added",
            minWidth: 72,
            idealWidth: 88,
            maxWidth: 2000,
            sortKey: "addedAt",
            hidden: false
        ),
        ColSpec(
            id: .fileFormat,
            title: "Codec",
            minWidth: 40,
            idealWidth: 52,
            maxWidth: 64,
            sortKey: "fileFormat",
            hidden: false
        ),
        ColSpec(
            id: .bitrate,
            title: "Bitrate",
            minWidth: 64,
            idealWidth: 80,
            maxWidth: 96,
            sortKey: "bitrate",
            hidden: false
        ),
        ColSpec(
            id: .sampleRate,
            title: "Sample Rate",
            minWidth: 64,
            idealWidth: 80,
            maxWidth: 96,
            sortKey: "sampleRate",
            hidden: true
        ),
        ColSpec(
            id: .shuffleExclude,
            title: "Shuffle Exclude",
            minWidth: 48,
            idealWidth: 56,
            maxWidth: 64,
            sortKey: "shuffleSortKey",
            hidden: true
        ),
        ColSpec(
            id: .composer,
            title: "Composer",
            minWidth: 80,
            idealWidth: 140,
            maxWidth: 2000,
            sortKey: "composer",
            hidden: true
        ),
        ColSpec(
            id: .bpm,
            title: "BPM",
            minWidth: 40,
            idealWidth: 52,
            maxWidth: 72,
            sortKey: "bpm",
            hidden: true
        ),
        ColSpec(
            id: .key,
            title: "Key",
            minWidth: 40,
            idealWidth: 56,
            maxWidth: 80,
            sortKey: "key",
            hidden: true
        ),
        ColSpec(
            id: .bitDepth,
            title: "Bit Depth",
            minWidth: 56,
            idealWidth: 64,
            maxWidth: 80,
            sortKey: "bitDepth",
            hidden: true
        ),
        ColSpec(
            id: .channelCount,
            title: "Channels",
            minWidth: 56,
            idealWidth: 64,
            maxWidth: 80,
            sortKey: "channelCount",
            hidden: true
        ),
        ColSpec(
            id: .isLossless,
            title: "Lossless",
            minWidth: 40,
            idealWidth: 52,
            maxWidth: 64,
            sortKey: "isLossless",
            hidden: true
        ),
        ColSpec(
            id: .skipCount,
            title: "Skips",
            minWidth: 36,
            idealWidth: 48,
            maxWidth: 56,
            sortKey: "skipCount",
            hidden: true
        ),
        ColSpec(
            id: .lastPlayedAt,
            title: "Last Played",
            minWidth: 72,
            idealWidth: 88,
            maxWidth: 2000,
            sortKey: "lastPlayedAt",
            hidden: true
        ),
        ColSpec(
            id: .fileSize,
            title: "File Size",
            minWidth: 64,
            idealWidth: 80,
            maxWidth: 96,
            sortKey: "fileSize",
            hidden: true
        ),
        ColSpec(
            id: .fileMtime,
            title: "Date Modified",
            minWidth: 72,
            idealWidth: 88,
            maxWidth: 2000,
            sortKey: "fileMtime",
            hidden: true
        ),
        ColSpec(
            id: .musicBrainzID,
            title: "MBID",
            minWidth: 80,
            idealWidth: 240,
            maxWidth: 320,
            sortKey: "musicBrainzID",
            hidden: true
        ),
    ]
}
