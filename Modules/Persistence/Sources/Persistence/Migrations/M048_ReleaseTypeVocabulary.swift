import GRDB

/// Migration 048: clear `albums.release_type` values outside the MusicBrainz
/// vocabulary (issue #403).
///
/// The M046 rescan stored whatever came first in RELEASETYPE, which on files
/// from one broken tagger was junk (`eleas`). The reader now returns nil for
/// anything outside the closed MusicBrainz type list; this removes what was
/// already stored. Mirrors `TrackTags.primaryReleaseTypes` and
/// `secondaryReleaseTypes` (Persistence cannot import Metadata).
enum M048ReleaseTypeVocabulary {
    static let knownTypes: [String] = [
        "album", "single", "ep", "broadcast", "other",
        "compilation", "soundtrack", "spokenword", "interview", "audiobook", "audio drama",
        "live", "remix", "dj-mix", "mixtape/street", "demo", "field recording",
    ]

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("048_release_type_vocabulary") { db in
            try self.apply(db)
        }
    }

    /// The migration body, callable from tests against a populated table.
    static func apply(_ db: GRDB.Database) throws {
        let placeholders = Array(repeating: "?", count: self.knownTypes.count).joined(separator: ", ")
        try db.execute(
            sql: "UPDATE albums SET release_type = NULL WHERE release_type IS NOT NULL AND release_type NOT IN (\(placeholders))",
            arguments: StatementArguments(self.knownTypes)
        )
    }
}
