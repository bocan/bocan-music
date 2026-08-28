import GRDB

/// Migration 041: backfill `artists.sort_name`.
///
/// The column existed since M001 and the ARTISTSORT tag was read from files,
/// but `ArtistRepository.findOrCreate(name:)` never stored it (issue #400).
/// Fill every NULL row with the derived form ("The Beatles" to "Beatles, The")
/// so sorting is right immediately; real tag values replace the derivation on
/// the next full rescan because tags win in `findOrCreate(name:sortName:)`.
/// Rows with no leading article stay NULL and order by display name.
enum M041ArtistSortNameBackfill {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("041_artist_sort_name_backfill") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM artists WHERE sort_name IS NULL")
            for row in rows {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                guard let derived = Artist.derivedSortName(from: name) else { continue }
                try db.execute(sql: "UPDATE artists SET sort_name = ? WHERE id = ?", arguments: [derived, id])
            }
        }
    }
}
