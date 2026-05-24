import Foundation

/// Identifies a single remote track on a specific Subsonic-compatible server,
/// at a specific transcoded format and bitrate. Equality is what the cache
/// keys on, so two different bitrates of the same song produce two cache
/// entries (matches what users actually expect when they flip the "stream
/// quality" setting mid-session).
public struct SubsonicStreamKey: Sendable, Hashable, Codable {
    public let serverID: UUID
    public let songID: String
    /// Transcode format requested from the server. Matches the Subsonic API
    /// `format` parameter (e.g. `"mp3"`, `"flac"`, `"opus"`, `"raw"`).
    public let format: String
    /// Max bitrate in kbps requested from the server, or `nil` for the
    /// server's default. Used by the cache key so two bitrates don't collide.
    public let bitrateKbps: Int?

    public init(serverID: UUID, songID: String, format: String, bitrateKbps: Int? = nil) {
        self.serverID = serverID
        self.songID = songID
        self.format = format
        self.bitrateKbps = bitrateKbps
    }

    /// Stable on-disk filename for this key. Subsonic song IDs can contain
    /// characters that are illegal in a path component (e.g. `/`), so we
    /// percent-encode them defensively before joining.
    public var cacheFilename: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safeSong = self.songID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "song"
        let kbps = self.bitrateKbps.map(String.init) ?? "default"
        return "\(safeSong)__\(self.format)__\(kbps).\(self.fileExtension)"
    }

    private var fileExtension: String {
        switch self.format.lowercased() {
        case "mp3": "mp3"
        case "flac": "flac"
        case "opus": "opus"
        case "ogg": "ogg"
        case "aac", "m4a": "m4a"
        case "wav": "wav"
        default: "bin"
        }
    }
}
