import Foundation

/// Parsed representation of a single CUE sheet.
///
/// CUE sheets describe one or more `FILE` blocks, each split into `TRACK`
/// entries with `INDEX 01 mm:ss:ff` offsets (75 frames per second).
public struct CUESheet: Sendable, Hashable {
    public struct Track: Sendable, Hashable {
        public let number: Int
        public let title: String?
        public let performer: String?
        public let startMs: Int64
        public let endMs: Int64?
        public let isrc: String?
        public init(
            number: Int,
            title: String?,
            performer: String?,
            startMs: Int64,
            endMs: Int64?,
            isrc: String?
        ) {
            self.number = number
            self.title = title
            self.performer = performer
            self.startMs = startMs
            self.endMs = endMs
            self.isrc = isrc
        }
    }

    public struct File: Sendable, Hashable {
        public let path: String
        public let absoluteURL: URL?
        public let tracks: [Track]
        public init(path: String, absoluteURL: URL?, tracks: [Track]) {
            self.path = path
            self.absoluteURL = absoluteURL
            self.tracks = tracks
        }
    }

    public let title: String?
    public let performer: String?
    public let files: [File]

    public init(title: String?, performer: String?, files: [File]) {
        self.title = title
        self.performer = performer
        self.files = files
    }
}

/// Reads CUE sheets.
public enum CUESheetReader {
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> CUESheet {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw PlaylistIOError.unreadable(url: sourceURL, reason: "Cannot decode CUE")
        }
        let baseDir = sourceURL?.deletingLastPathComponent()
        let lines = M3UReader.splitLines(text)

        var sheetTitle: String?
        var sheetPerformer: String?
        var files: [CUESheet.File] = []

        // Per-file builders.
        var currentFilePath: String?
        var currentFileURL: URL?
        var trackBuilders: [TrackBuilder] = []

        func flushFile() {
            guard let path = currentFilePath else { return }
            let resolved = self.finaliseTracks(trackBuilders, fileEndMs: nil)
            files.append(CUESheet.File(path: path, absoluteURL: currentFileURL, tracks: resolved))
            currentFilePath = nil
            currentFileURL = nil
            trackBuilders = []
        }

        var currentTrack: TrackBuilder?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Tokenise leading uppercase command + remainder.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let cmd = parts.first?.uppercased() else { continue }
            let rest = parts.count > 1 ? String(parts[1]) : ""

            switch cmd {
            case "TITLE":
                let val = self.unquote(rest)
                if currentTrack != nil {
                    currentTrack?.title = val
                } else {
                    sheetTitle = val
                }
            case "PERFORMER":
                let val = self.unquote(rest)
                if currentTrack != nil {
                    currentTrack?.performer = val
                } else {
                    sheetPerformer = val
                }
            case "FILE":
                if currentTrack != nil {
                    trackBuilders.append(currentTrack!)
                    currentTrack = nil
                }
                flushFile()
                let payload = self.parseFileArgs(rest)
                currentFilePath = payload
                currentFileURL = M3UReader.resolveURL(rawPath: payload, baseDir: baseDir)
            case "TRACK":
                if currentTrack != nil {
                    trackBuilders.append(currentTrack!)
                }
                let trackParts = rest.split(separator: " ", omittingEmptySubsequences: true)
                let num = trackParts.first.flatMap { Int($0) } ?? (trackBuilders.count + 1)
                currentTrack = TrackBuilder(number: num)
            case "INDEX":
                // INDEX nn mm:ss:ff
                let idxParts = rest.split(separator: " ", omittingEmptySubsequences: true)
                guard idxParts.count >= 2,
                      let idxNum = Int(idxParts[0]) else { continue }
                let timeStr = String(idxParts[1])
                guard let ms = parseMSF(timeStr) else { continue }
                if idxNum == 1 {
                    currentTrack?.startMs = ms
                }
            case "ISRC":
                currentTrack?.isrc = rest.trimmingCharacters(in: .whitespaces)
            case "REM":
                continue // ignored
            default:
                continue
            }
        }

        if currentTrack != nil {
            trackBuilders.append(currentTrack!)
            currentTrack = nil
        }
        flushFile()

        return CUESheet(title: sheetTitle, performer: sheetPerformer, files: files)
    }

    // MARK: - Helpers

    private struct TrackBuilder {
        let number: Int
        var title: String?
        var performer: String?
        var startMs: Int64?
        var isrc: String?
    }

    /// Build final tracks by deriving end-times from the next track's start.
    private static func finaliseTracks(_ builders: [TrackBuilder], fileEndMs: Int64?) -> [CUESheet.Track] {
        let sorted = builders.sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        var out: [CUESheet.Track] = []
        for (idx, b) in sorted.enumerated() {
            let next = idx + 1 < sorted.count ? sorted[idx + 1].startMs : fileEndMs
            out.append(CUESheet.Track(
                number: b.number,
                title: b.title,
                performer: b.performer,
                startMs: b.startMs ?? 0,
                endMs: next,
                isrc: b.isrc
            ))
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            t.removeFirst()
            t.removeLast()
        }
        return t
    }

    /// Parse `"path" TYPE` or `path TYPE` — return the path component.
    private static func parseFileArgs(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            // Find the closing quote.
            if let endQuote = trimmed.dropFirst().firstIndex(of: "\"") {
                return String(trimmed[trimmed.index(after: trimmed.startIndex) ..< endQuote])
            }
        }
        // Otherwise: split off the trailing type token.
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2 {
            return parts.dropLast().joined(separator: " ")
        }
        return trimmed
    }

    /// Parse `mm:ss:ff` (75 frames per second) → milliseconds.
    static func parseMSF(_ s: String) -> Int64? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let m = Int64(parts[0]),
              let sec = Int64(parts[1]),
              let f = Int64(parts[2]) else { return nil }
        let totalFrames = (m * 60 + sec) * 75 + f
        // 1 frame = 1/75 s = 13.333... ms; multiply then divide for integer arithmetic.
        return (totalFrames * 1000) / 75
    }
}
