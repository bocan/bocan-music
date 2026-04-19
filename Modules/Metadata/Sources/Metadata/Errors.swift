import Foundation

/// Errors thrown by the Metadata module.
public enum MetadataError: Error, Sendable, CustomStringConvertible {
    /// TagLib could not open or parse the file.
    case unreadableFile(URL, String)

    /// The file format is not supported by TagLib.
    case unsupportedFormat(URL)

    /// Bridge returned an unexpected nil value.
    case bridgeFailure(String)

    public var description: String {
        switch self {
        case let .unreadableFile(url, reason):
            "Metadata: cannot read \(url.lastPathComponent): \(reason)"
        case let .unsupportedFormat(url):
            "Metadata: unsupported format \(url.pathExtension) at \(url.lastPathComponent)"
        case let .bridgeFailure(msg):
            "Metadata bridge failure: \(msg)"
        }
    }
}
