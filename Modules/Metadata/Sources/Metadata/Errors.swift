import Foundation

/// Errors thrown by the Metadata module.
///
/// Conforms to `LocalizedError` so `localizedDescription` carries the reason.
/// Without it, Foundation reports "(Metadata.MetadataError error 3.)", which
/// is what callers that store `error.localizedDescription` end up showing to
/// the user (#469).
public enum MetadataError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// TagLib could not open or parse the file.
    case unreadableFile(URL, String)

    /// The file format is not supported by TagLib.
    case unsupportedFormat(URL)

    /// Bridge returned an unexpected nil value.
    case bridgeFailure(String)

    /// TagLib could not write tags to the file.
    case writeFailed(URL, String)

    /// The file is read-only (EACCES).
    case readOnlyFile(URL)

    public var description: String {
        switch self {
        case let .unreadableFile(url, reason):
            "Metadata: cannot read \(url.lastPathComponent): \(reason)"
        case let .unsupportedFormat(url):
            "Metadata: unsupported format \(url.pathExtension) at \(url.lastPathComponent)"
        case let .bridgeFailure(msg):
            "Metadata bridge failure: \(msg)"
        case let .writeFailed(url, reason):
            "Metadata: cannot write \(url.lastPathComponent): \(reason)"
        case let .readOnlyFile(url):
            "Metadata: file is read-only: \(url.lastPathComponent)"
        }
    }

    public var errorDescription: String? {
        self.description
    }
}
