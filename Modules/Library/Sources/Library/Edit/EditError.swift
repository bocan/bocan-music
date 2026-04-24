import Foundation

/// Errors thrown by the metadata-editing subsystem.
public enum EditError: Error, Sendable, CustomStringConvertible {
    /// The track was not found in the database.
    case trackNotFound(Int64)

    /// The file at the given URL could not be written (wraps the underlying error).
    case fileWriteFailed(URL, String)

    /// The file is read-only.
    case readOnlyFile(URL)

    /// The edit operation was cancelled.
    case cancelled

    /// A batch edit partially failed; contains errors per track ID.
    case partial([Int64: String])

    public var description: String {
        switch self {
        case let .trackNotFound(id):
            "Edit: track \(id) not found"
        case let .fileWriteFailed(url, reason):
            "Edit: write failed for \(url.lastPathComponent): \(reason)"
        case let .readOnlyFile(url):
            "Edit: file is read-only: \(url.lastPathComponent)"
        case .cancelled:
            "Edit: cancelled"
        case let .partial(errors):
            "Edit: \(errors.count) file(s) failed"
        }
    }
}
