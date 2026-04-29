import Foundation

/// Reads XSPF (XML Shareable Playlist Format) playlists.
///
/// Spec: <http://xspf.org/ns/0/>. Tracks live under
/// `<playlist><trackList><track>...`. We honour `location`, `title`,
/// `creator`, `album`, and `duration` (milliseconds).
public enum XSPFReader {
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> PlaylistPayload {
        let parser = XMLParser(data: data)
        let delegate = XSPFParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map { String(describing: $0) } ?? "unknown XML error"
            throw PlaylistIOError.malformed(format: "XSPF", reason: reason)
        }

        let baseDir = sourceURL?.deletingLastPathComponent()
        let entries: [PlaylistPayload.Entry] = delegate.tracks.map { raw in
            let location = raw.location ?? ""
            let absolute = M3UReader.resolveURL(rawPath: location, baseDir: baseDir)
            let dur: TimeInterval? = raw.durationMs.map { TimeInterval($0) / 1000.0 }
            return PlaylistPayload.Entry(
                path: location,
                absoluteURL: absolute,
                durationHint: dur,
                titleHint: raw.title,
                artistHint: raw.creator,
                albumHint: raw.album
            )
        }

        let name = delegate.playlistTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "Imported Playlist"

        return PlaylistPayload(name: name, entries: entries)
    }
}

private final class XSPFParserDelegate: NSObject, XMLParserDelegate {
    struct RawTrack {
        var location: String?
        var title: String?
        var creator: String?
        var album: String?
        var durationMs: Int?
    }

    var playlistTitle: String?
    var tracks: [RawTrack] = []

    private var inPlaylistTitle = false
    private var inTrack = false
    private var currentTrack = RawTrack()
    private var currentElement = ""
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.lowercased()
        self.currentElement = name
        self.currentText = ""
        if name == "track" {
            self.inTrack = true
            self.currentTrack = RawTrack()
        } else if name == "title", !self.inTrack {
            self.inPlaylistTitle = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        self.currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = self.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.inTrack {
            switch name {
            case "location":
                if self.currentTrack.location == nil { self.currentTrack.location = value }
            case "title": self.currentTrack.title = value
            case "creator": self.currentTrack.creator = value
            case "album": self.currentTrack.album = value
            case "duration":
                if let ms = Int(value), ms > 0 { self.currentTrack.durationMs = ms }
            case "track":
                self.tracks.append(self.currentTrack)
                self.inTrack = false
            default: break
            }
        } else {
            if name == "title", self.inPlaylistTitle {
                self.playlistTitle = value
                self.inPlaylistTitle = false
            }
        }
        self.currentText = ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
