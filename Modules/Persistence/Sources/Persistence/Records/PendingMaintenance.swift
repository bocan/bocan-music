import Foundation
import GRDB

/// A one-time housekeeping task a migration has asked the app to run, in the
/// spirit of `/forcefsck`: the migration that knows a re-read is needed leaves
/// the request inside its own transaction, and the app clears it when the
/// task completes (issue #425). Lives with the library it applies to.
public struct PendingMaintenance: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "pending_maintenance"

    /// Well-known task names.
    public enum Task {
        /// Re-read every file so importer-derived columns backfill.
        public static let fullRescan = "full_rescan"
    }

    /// Task name, e.g. `Task.fullRescan`.
    public var task: String
    /// The migration (or other actor) that asked, e.g. `045_pending_maintenance`.
    public var requestedBy: String
    /// Unix seconds.
    public var requestedAt: Int64

    public init(task: String, requestedBy: String, requestedAt: Int64) {
        self.task = task
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
    }

    enum CodingKeys: String, CodingKey {
        case task
        case requestedBy = "requested_by"
        case requestedAt = "requested_at"
    }
}
