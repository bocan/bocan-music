import GRDB

/// Widens the `radio_stations` machine-owned profile (phase 27-5): the
/// measured container, sample rate, and channel count from the last
/// successful connect, so the station info sheet can answer "what is this
/// stream, really" even offline. Nullable like the rest of the profile;
/// M036 shipped on `main`, so these columns append rather than edit it.
enum M037RadioStationStreamDetails {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("037_radio_station_stream_details") { db in
            try db.execute(sql: "ALTER TABLE radio_stations ADD COLUMN last_container TEXT")
            try db.execute(sql: "ALTER TABLE radio_stations ADD COLUMN last_sample_rate_hz INTEGER")
            try db.execute(sql: "ALTER TABLE radio_stations ADD COLUMN last_channels INTEGER")
        }
    }
}
