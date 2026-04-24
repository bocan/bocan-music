import Foundation

// MARK: - CoverArtFetcher

/// Protocol for services that can search for and download cover art.
public protocol CoverArtFetcher: Sendable {
    /// Searches for cover art candidates matching `artist` + `album`.
    func search(artist: String, album: String) async throws -> [CoverArtCandidate]

    /// Downloads the full-resolution (or thumbnail) image for `candidate`.
    func image(for candidate: CoverArtCandidate, size: CoverArtSize) async throws -> Data
}

// MARK: - CoverArtSize

public enum CoverArtSize: Sendable {
    /// 500 px thumbnail — fast, for preview grids.
    case thumbnail
    /// Full-resolution original.
    case full
}
