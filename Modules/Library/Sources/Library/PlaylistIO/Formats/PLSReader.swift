import Foundation

/// Reads PLS (INI-style) playlists.
///
/// Format reference (Winamp/SHOUTcast):
/// ```
/// [playlist]
/// File1=/path/to/song.mp3
/// Title1=Song Title
/// Length1=240
/// File2=...
/// NumberOfEntries=2
/// Version=2
/// ```
///
/// Recovers from a wrong/missing `NumberOfEntries` by trusting the highest
/// `File<n>` index found.
public enum PLSReader {
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> PlaylistPayload {
        guard let text = String(data: stripBOM(data), encoding: .utf8)
            ?? String(data: stripBOM(data), encoding: .windowsCP1252)
            ?? String(data: stripBOM(data), encoding: .isoLatin1) else {
            throw PlaylistIOError.unreadable(url: sourceURL, reason: "Cannot decode PLS as text")
        }

        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: TimeInterval] = [:]
        var sawHeader = false

        let lines = M3UReader.splitLines(text)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.lowercased() == "[playlist]" { sawHeader = true
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let (kind, idx) = Self.parseKey(key) {
                switch kind {
                case .file: files[idx] = value
                case .title: titles[idx] = value
                case .length: lengths[idx] = TimeInterval(value).flatMap { $0 > 0 ? $0 : nil } ?? 0
                }
            }
        }

        if !sawHeader, files.isEmpty {
            throw PlaylistIOError.malformed(format: "PLS", reason: "Missing [playlist] header and no entries")
        }

        let baseDir = sourceURL?.deletingLastPathComponent()
        let sortedIndexes = files.keys.sorted()
        var entries: [PlaylistPayload.Entry] = []
        entries.reserveCapacity(sortedIndexes.count)
        for idx in sortedIndexes {
            // swiftlint:disable:next force_unwrapping
            let path = files[idx]!
            let dur = (lengths[idx] ?? 0) > 0 ? lengths[idx] : nil
            let title = titles[idx]
            let absolute = M3UReader.resolveURL(rawPath: path, baseDir: baseDir)
            entries.append(PlaylistPayload.Entry(
                path: path,
                absoluteURL: absolute,
                durationHint: dur,
                titleHint: title,
                artistHint: nil,
                albumHint: nil
            ))
        }

        let name = sourceURL?.deletingPathExtension().lastPathComponent ?? "Imported Playlist"
        return PlaylistPayload(name: name, entries: entries)
    }

    private enum Kind { case file, title, length }

    private static func parseKey(_ key: String) -> (Kind, Int)? {
        // FileN, TitleN, LengthN — case-insensitive; N >= 1.
        let lower = key.lowercased()
        let prefix: String
        let kind: Kind
        if lower.hasPrefix("file") { prefix = "file"
            kind = .file
        } else if lower.hasPrefix("title") { prefix = "title"
            kind = .title
        } else if lower.hasPrefix("length") { prefix = "length"
            kind = .length
        } else { return nil }
        guard let n = Int(lower.dropFirst(prefix.count)), n >= 1 else { return nil }
        return (kind, n)
    }

    private static func stripBOM(_ data: Data) -> Data {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return data.dropFirst(3)
        }
        return data
    }
}
