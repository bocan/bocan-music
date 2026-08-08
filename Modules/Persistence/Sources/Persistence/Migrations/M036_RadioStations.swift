import GRDB

/// Adds `radio_stations` (phase 27-1): the local, user-curated internet radio
/// station catalog. `stream_url` is UNIQUE because it is the catalog's
/// identity key: importing the same playlist twice must be idempotent (27-4
/// inserts through it and skips rows that already exist). The nullable
/// profile columns (genre, description, codec, bitrate, last connect) are
/// machine-owned: backfilled from ICY headers and measured stream parameters
/// on a successful connect (27-5), never required, and kept so the station
/// info sheet works offline.
enum M036RadioStations {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("036_radio_stations") { db in
            try db.execute(sql: """
                CREATE TABLE radio_stations (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    stream_url TEXT NOT NULL UNIQUE,
                    home_page_url TEXT,
                    genre TEXT,
                    station_description TEXT,
                    last_codec TEXT,
                    last_bitrate_kbps INTEGER,
                    last_connected_at INTEGER,
                    added_at INTEGER NOT NULL
                )
            """)
        }
    }
}
