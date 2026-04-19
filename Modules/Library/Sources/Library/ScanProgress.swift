import Foundation

/// Events emitted by ``LibraryScanner`` during a scan.
public enum ScanProgress: Sendable {
    case started(rootCount: Int)
    case walking(currentPath: String, walked: Int)
    case processed(url: URL, outcome: ImportOutcome)
    case removed(trackID: Int64)
    case error(url: URL?, error: Error)
    case finished(Summary)

    public enum ImportOutcome: Sendable {
        case inserted(trackID: Int64)
        case updated(trackID: Int64)
        case skippedUnchanged
        case conflict(trackID: Int64)
    }

    public struct Summary: Sendable {
        public let inserted: Int
        public let updated: Int
        public let removed: Int
        public let skipped: Int
        public let errors: Int
        public let duration: Duration
    }
}
