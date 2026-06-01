/// Severity of a captured log line, ordered low -> high for min-level filters.
public enum LogLevel: Int, Sendable, CaseIterable, Comparable, Codable {
    case trace = 0
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Upper-case label shown in the console ("DEBUG", "WARNING", ...).
    public var label: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARNING"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}
