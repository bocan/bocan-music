import Foundation

// MARK: - SidecarArt

/// Locates external cover-art files sitting beside the music (#388):
/// `cover.jpg`, `folder.png`, and friends — the convention plenty of FLAC
/// rips use instead of embedded art.
///
/// Matching is case-insensitive on both stem and extension. Stems are
/// checked in priority order so `cover.*` beats `folder.*` beats `front.*`
/// beats `albumart*` when a folder carries several. Decoding downstream goes
/// through ImageIO (content-sniffed), so every listed container displays
/// regardless of how the cache files it.
enum SidecarArt {
    /// Filename stems that mean "this image is the album cover", in
    /// priority order.
    static let stems = ["cover", "folder", "front", "albumart"]

    /// Image containers accepted as sidecar art.
    static let extensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif"]

    /// Whether `url` names a sidecar cover-art file.
    static func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard self.extensions.contains(ext) else { return false }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return self.stems.contains(stem)
    }

    /// The best sidecar art file in `directory`, or nil. One directory
    /// listing; ties break by stem priority, then extension order.
    static func findURL(inDirectory directory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        // Lowercased name → real name, first-wins so duplicate casings are
        // deterministic.
        var byLowercased: [String: String] = [:]
        for name in names where byLowercased[name.lowercased()] == nil {
            byLowercased[name.lowercased()] = name
        }
        for stem in self.stems {
            for ext in self.extensions {
                if let real = byLowercased["\(stem).\(ext)"] {
                    return directory.appendingPathComponent(real)
                }
            }
        }
        return nil
    }

    /// The MIME type for a sidecar file's extension, for `ExtractedCoverArt`.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":
            "image/jpeg"

        case "png":
            "image/png"

        case "gif":
            "image/gif"

        case "webp":
            "image/webp"

        case "heic":
            "image/heic"

        case "avif":
            "image/avif"

        default:
            "application/octet-stream"
        }
    }
}
