import Foundation

/// Writes M3U / M3U8 playlists.
///
/// `.m3u8` is always UTF-8 (no BOM by default). `.m3u` is also written as UTF-8
/// for round-trip safety; readers that can't handle it are out of spec by 2024.
public enum M3UWriter {
    public struct Options: Sendable {
        public var lineEnding: String
        public var pathMode: PathMode
        public var includeExtInf: Bool
        public var includeExtArt: Bool
        public var includeExtAlb: Bool

        public init(
            lineEnding: String = "\n",
            pathMode: PathMode = .absolute,
            includeExtInf: Bool = true,
            includeExtArt: Bool = false,
            includeExtAlb: Bool = false
        ) {
            self.lineEnding = lineEnding
            self.pathMode = pathMode
            self.includeExtInf = includeExtInf
            self.includeExtArt = includeExtArt
            self.includeExtAlb = includeExtAlb
        }
    }

    public static func write(_ payload: PlaylistPayload, options: Options = Options()) -> String {
        var lines: [String] = []
        lines.append("#EXTM3U")
        if !payload.name.isEmpty {
            lines.append("#PLAYLIST:" + payload.name)
        }
        for entry in payload.entries {
            if options.includeExtInf {
                let dur = entry.durationHint.map { Int($0.rounded()) } ?? -1
                let display = Self.displayString(for: entry)
                lines.append("#EXTINF:\(dur),\(display)")
            }
            if options.includeExtArt, let a = entry.artistHint, !a.isEmpty {
                lines.append("#EXTART:" + a)
            }
            if options.includeExtAlb, let a = entry.albumHint, !a.isEmpty {
                lines.append("#EXTALB:" + a)
            }
            lines.append(Self.renderPath(for: entry, mode: options.pathMode))
        }
        return lines.joined(separator: options.lineEnding) + options.lineEnding
    }

    static func displayString(for entry: PlaylistPayload.Entry) -> String {
        switch (entry.artistHint, entry.titleHint) {
        case let (artist?, title?): "\(artist) - \(title)"
        case let (_, title?): title
        case let (artist?, _): artist
        case (nil, nil): ""
        }
    }

    static func renderPath(for entry: PlaylistPayload.Entry, mode: PathMode) -> String {
        switch mode {
        case .absolute:
            if let url = entry.absoluteURL, url.isFileURL { return url.path }
            return entry.path
        case let .relative(root):
            guard let url = entry.absoluteURL, url.isFileURL else { return entry.path }
            return Self.relativePath(of: url, to: root) ?? url.path
        }
    }

    /// POSIX-style relative path of `target` from directory `root`.
    /// Falls back to nil when the two have no common ancestor.
    static func relativePath(of target: URL, to root: URL) -> String? {
        let targetComponents = target.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard !targetComponents.isEmpty, !rootComponents.isEmpty else { return nil }
        var common = 0
        while common < targetComponents.count, common < rootComponents.count,
              targetComponents[common] == rootComponents[common] {
            common += 1
        }
        // Require they at least share the root "/".
        guard common >= 1 else { return nil }
        let upHops = rootComponents.count - common
        let downHops = targetComponents[common...]
        var pieces = Array(repeating: "..", count: upHops)
        pieces.append(contentsOf: downHops)
        return pieces.joined(separator: "/")
    }
}
