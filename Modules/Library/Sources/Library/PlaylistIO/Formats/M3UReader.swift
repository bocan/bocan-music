import Foundation
import Observability

/// Reads M3U / M3U8 playlists.
///
/// `.m3u8` is required UTF-8 (with optional BOM); `.m3u` is parsed as UTF-8 first
/// and falls back to Windows-1252 (Latin-1 superset) if invalid.
///
/// Supports the extended directives in common use:
///   `#EXTM3U`      — header marker.
///   `#EXTINF:<seconds>,<artist> - <title>` — per-entry duration + display string.
///   `#EXTART:<artist>`  — per-entry artist.
///   `#EXTALB:<album>`   — per-entry album.
public enum M3UReader {
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> PlaylistPayload {
        let (text, _) = try Self.decode(data: data, sourceURL: sourceURL)
        let playlistName = sourceURL?.deletingPathExtension().lastPathComponent ?? "Imported Playlist"
        let baseDir = sourceURL?.deletingLastPathComponent()

        var entries: [PlaylistPayload.Entry] = []
        var pendingDuration: TimeInterval?
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingAlbum: String?

        let lines = Self.splitLines(text)

        for rawLine in lines {
            // Strip BOM characters and trim.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    let payload = String(line.dropFirst("#EXTINF:".count))
                    let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    if let durStr = parts.first {
                        let cleaned = String(durStr).trimmingCharacters(in: .whitespaces)
                        if let dur = TimeInterval(cleaned), dur > 0 { pendingDuration = dur }
                    }
                    if parts.count > 1 {
                        let display = String(parts[1])
                        // Convention: "Artist - Title". Parse leniently.
                        if let dash = display.range(of: " - ") {
                            pendingArtist = String(display[..<dash.lowerBound])
                                .trimmingCharacters(in: .whitespaces)
                            pendingTitle = String(display[dash.upperBound...])
                                .trimmingCharacters(in: .whitespaces)
                        } else {
                            pendingTitle = display.trimmingCharacters(in: .whitespaces)
                        }
                    }
                } else if line.hasPrefix("#EXTART:") {
                    pendingArtist = String(line.dropFirst("#EXTART:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#EXTALB:") {
                    pendingAlbum = String(line.dropFirst("#EXTALB:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                // Other directives (e.g. #PLAYLIST, #EXTGENRE, #EXTM3U) are ignored.
                continue
            }

            // Treat as a path or URL.
            let entry = Self.makeEntry(
                rawPath: line,
                duration: pendingDuration,
                title: pendingTitle,
                artist: pendingArtist,
                album: pendingAlbum,
                baseDir: baseDir
            )
            entries.append(entry)
            pendingDuration = nil
            pendingTitle = nil
            pendingArtist = nil
            pendingAlbum = nil
        }

        return PlaylistPayload(name: playlistName, entries: entries)
    }

    // MARK: - Helpers

    static func splitLines(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var iter = text.unicodeScalars.makeIterator()
        while let s = iter.next() {
            if s == "\r" {
                out.append(current)
                current = ""
            } else if s == "\n" {
                out.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(s)
            }
        }
        out.append(current)
        return out
    }

    static func decode(data: Data, sourceURL: URL?) throws -> (String, String.Encoding) {
        // Strip UTF-8 BOM if present.
        var bytes = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.count >= 3, Array(bytes.prefix(3)) == bom {
            bytes.removeFirst(3)
        }
        if let s = String(data: bytes, encoding: .utf8) { return (s, .utf8) }
        let isM3U8 = sourceURL?.pathExtension.lowercased() == "m3u8"
        if !isM3U8, let s = String(data: bytes, encoding: .windowsCP1252) {
            return (s, .windowsCP1252)
        }
        if let s = String(data: bytes, encoding: .isoLatin1) {
            return (s, .isoLatin1)
        }
        throw PlaylistIOError.unreadable(url: sourceURL, reason: "Cannot decode as UTF-8 or Windows-1252")
    }

    static func makeEntry(
        rawPath: String,
        duration: TimeInterval?,
        title: String?,
        artist: String?,
        album: String?,
        baseDir: URL?
    ) -> PlaylistPayload.Entry {
        let absoluteURL = Self.resolveURL(rawPath: rawPath, baseDir: baseDir)
        return PlaylistPayload.Entry(
            path: rawPath,
            absoluteURL: absoluteURL,
            durationHint: duration,
            titleHint: title,
            artistHint: artist,
            albumHint: album
        )
    }

    /// Resolve an entry path to an absolute file URL.
    static func resolveURL(rawPath: String, baseDir: URL?) -> URL? {
        // file:// URL?
        if let url = URL(string: rawPath), url.scheme == "file" {
            return url
        }
        // Other schemes (http, https) — treat as opaque, no absolute URL.
        if let url = URL(string: rawPath), let scheme = url.scheme, !scheme.isEmpty,
           scheme != "file" {
            return nil
        }
        // Absolute path?
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        // Windows-style absolute? `C:\...` — best effort: ignore drive, treat as relative on macOS.
        // Relative path:
        if let baseDir {
            return URL(fileURLWithPath: rawPath, relativeTo: baseDir).absoluteURL
        }
        return nil
    }
}
