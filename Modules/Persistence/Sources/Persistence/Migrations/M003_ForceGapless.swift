import Foundation
import GRDB

/// Phase 5.5 migration: adds `force_gapless` flag to the `albums` table.
///
/// When set, `QueuePlayer` bypasses the "no padding tags → skip gapless"
/// short-circuit and passes the pair to `GaplessScheduler` even without
/// iTunSMPB / Vorbis padding data.  Different sample rates still require
/// `FormatBridge`; this flag only affects the padding-tag gate.
enum M003ForceGapless {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("003_force_gapless") { db in
            try db.execute(
                sql: "ALTER TABLE albums ADD COLUMN force_gapless INTEGER NOT NULL DEFAULT 0"
            )
        }
    }
}
