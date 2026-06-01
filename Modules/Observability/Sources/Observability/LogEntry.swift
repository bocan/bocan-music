import Foundation

/// One captured log line. The `message` is already formatted and redacted
/// (it is the exact string handed to `os.Logger`), so storing it is safe.
public struct LogEntry: Identifiable, Sendable, Hashable {
    /// Monotonic sequence number assigned by `LogStore`. Stable SwiftUI identity,
    /// total ordering, and cheap dedup across backfill + live stream.
    public let id: UInt64
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
}
