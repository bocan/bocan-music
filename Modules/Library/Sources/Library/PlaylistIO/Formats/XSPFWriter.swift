import Foundation

/// Writes XSPF (XML Shareable Playlist Format) playlists.
public enum XSPFWriter {
    public struct Options: Sendable {
        public var pathMode: PathMode
        public init(pathMode: PathMode = .absolute) {
            self.pathMode = pathMode
        }
    }

    public static func write(_ payload: PlaylistPayload, options: Options = Options()) -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        out += #"<playlist version="1" xmlns="http://xspf.org/ns/0/">"# + "\n"
        out += "  <title>\(self.escape(payload.name))</title>\n"
        out += "  <trackList>\n"
        for entry in payload.entries {
            out += "    <track>\n"
            let location = self.locationString(for: entry, mode: options.pathMode)
            out += "      <location>\(self.escape(location))</location>\n"
            if let title = entry.titleHint, !title.isEmpty {
                out += "      <title>\(self.escape(title))</title>\n"
            }
            if let creator = entry.artistHint, !creator.isEmpty {
                out += "      <creator>\(self.escape(creator))</creator>\n"
            }
            if let album = entry.albumHint, !album.isEmpty {
                out += "      <album>\(self.escape(album))</album>\n"
            }
            if let dur = entry.durationHint, dur > 0 {
                out += "      <duration>\(Int((dur * 1000).rounded()))</duration>\n"
            }
            out += "    </track>\n"
        }
        out += "  </trackList>\n"
        out += "</playlist>\n"
        return out
    }

    private static func locationString(for entry: PlaylistPayload.Entry, mode: PathMode) -> String {
        switch mode {
        case .absolute:
            if let url = entry.absoluteURL, url.isFileURL {
                return url.absoluteString
            }
            return entry.path
        case let .relative(root):
            guard let url = entry.absoluteURL, url.isFileURL else { return entry.path }
            if let rel = M3UWriter.relativePath(of: url, to: root) {
                return rel
            }
            return url.absoluteString
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.append(c)
            }
        }
        return out
    }
}
