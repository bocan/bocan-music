import Foundation

/// Writes PLS playlists.
public enum PLSWriter {
    public struct Options: Sendable {
        public var lineEnding: String
        public var pathMode: PathMode

        public init(lineEnding: String = "\n", pathMode: PathMode = .absolute) {
            self.lineEnding = lineEnding
            self.pathMode = pathMode
        }
    }

    public static func write(_ payload: PlaylistPayload, options: Options = Options()) -> String {
        var lines: [String] = []
        lines.append("[playlist]")
        for (idx, entry) in payload.entries.enumerated() {
            let n = idx + 1
            lines.append("File\(n)=\(M3UWriter.renderPath(for: entry, mode: options.pathMode))")
            if let t = entry.titleHint, !t.isEmpty {
                lines.append("Title\(n)=\(t)")
            } else if let a = entry.artistHint, !a.isEmpty {
                lines.append("Title\(n)=\(a)")
            }
            let dur = entry.durationHint.map { Int($0.rounded()) } ?? -1
            lines.append("Length\(n)=\(dur)")
        }
        lines.append("NumberOfEntries=\(payload.entries.count)")
        lines.append("Version=2")
        return lines.joined(separator: options.lineEnding) + options.lineEnding
    }
}
