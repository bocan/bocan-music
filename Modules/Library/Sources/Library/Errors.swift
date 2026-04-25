import Foundation

/// Errors thrown by the Library module.
public enum LibraryError: Error, Sendable, CustomStringConvertible {
    /// A security-scoped bookmark could not be resolved or accessed.
    case bookmarkStale(URL)

    /// A root folder path could not be converted to a URL.
    case invalidPath(String)

    /// The library database is inaccessible.
    case databaseUnavailable(String)

    /// A scan was attempted when one was already running.
    case scanAlreadyInProgress

    /// A root with the given ID was not found.
    case rootNotFound(Int64)

    /// A track has no database ID (not yet persisted).
    case missingID

    /// A track's `fileURL` string could not be parsed into a valid URL.
    case invalidFileURL(String)

    /// Wraps an underlying system error.
    case underlying(Error)

    public var description: String {
        switch self {
        case let .bookmarkStale(url):
            "Library: bookmark stale for \(url.path)"
        case let .invalidPath(path):
            "Library: invalid path '\(path)'"
        case let .databaseUnavailable(reason):
            "Library: database unavailable: \(reason)"
        case .scanAlreadyInProgress:
            "Library: a scan is already in progress"
        case let .rootNotFound(id):
            "Library: root \(id) not found"
        case .missingID:
            "Library: track has no database ID"
        case let .invalidFileURL(raw):
            "Library: invalid file URL '\(raw)'"
        case let .underlying(err):
            "Library: \(err)"
        }
    }
}
