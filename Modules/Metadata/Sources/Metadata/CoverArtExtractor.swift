import CryptoKit
import Foundation

// MARK: - Types

/// Cover art extracted from a file's tags.
public struct ExtractedCoverArt: Sendable {
    /// Raw image bytes.
    public let data: Data

    /// MIME type, e.g. `"image/jpeg"`.
    public let mimeType: String

    /// APIC picture type (3 = front cover, 0 = other).
    public let pictureType: Int

    /// SHA-256 hex digest of `data`.
    public let sha256: String

    /// Embedded art larger than this is unusual and expensive to hash synchronously.
    static let maxHashBytes = 50 * 1024 * 1024 // 50 MB

    init(data: Data, mimeType: String, pictureType: Int) {
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
        if data.count <= Self.maxHashBytes {
            self.sha256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            // Oversized art: skip the full hash to avoid a blocking allocation.
            // Use a random token so deduplication is skipped rather than wrong.
            self.sha256 = UUID().uuidString
        }
    }

    /// File extension inferred from `mimeType`.
    public var fileExtension: String {
        switch self.mimeType.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/gif": "gif"
        default: "bin"
        }
    }
}

// MARK: - CoverArtExtractor

/// Extracts and deduplicates cover art from tag data.
public enum CoverArtExtractor {
    /// Returns all embedded images, deduped by SHA-256 hash.
    public static func extract(from rawArts: [RawCoverArt]) -> [ExtractedCoverArt] {
        var seen = Set<String>()
        var result: [ExtractedCoverArt] = []
        // Front covers first
        let sorted = rawArts.sorted { $0.pictureType == 3 && $1.pictureType != 3 }
        for art in sorted {
            let extracted = ExtractedCoverArt(
                data: art.data,
                mimeType: art.mimeType,
                pictureType: art.pictureType
            )
            guard seen.insert(extracted.sha256).inserted else { continue }
            result.append(extracted)
        }
        return result
    }
}

// MARK: - RawCoverArt (bridge type)

/// Unprocessed cover art data from the bridge.
public struct RawCoverArt: Sendable {
    public let data: Data
    public let mimeType: String
    public let pictureType: Int

    public init(data: Data, mimeType: String, pictureType: Int) {
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
    }
}
