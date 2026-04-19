import Foundation

/// Writes tag metadata back to audio files.
///
/// - Note: Phase 8 implementation. Currently a stub.
public struct TagWriter: Sendable {
    public init() {}

    /// Writes `tags` to the file at `url`.
    ///
    /// - Throws: ``MetadataError/unsupportedFormat(_:)`` always (not yet implemented).
    public func write(_ tags: TrackTags, to url: URL) throws {
        throw MetadataError.unsupportedFormat(url)
    }
}
