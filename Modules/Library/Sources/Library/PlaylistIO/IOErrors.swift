import Foundation

/// Errors thrown by the PlaylistIO subsystem.
public enum PlaylistIOError: Error, Sendable, Equatable {
    /// The supplied data could not be decoded as the expected text encoding.
    case unreadable(url: URL?, reason: String)
    /// The format-specific parser rejected the input.
    case malformed(format: String, reason: String)
    /// No payload could be sniffed from the input.
    case unrecognisedFormat(url: URL?)
    /// A write target could not be opened or written to.
    case writeFailed(url: URL, underlying: String)
    /// A track lookup failed catastrophically (DB error wrapped).
    case lookupFailed(reason: String)
}
