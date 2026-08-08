import Foundation
import Observability

// MARK: - RemotePlaylistResolution

/// What a fetched playlist URL turned out to contain (phase 27-3).
public enum RemotePlaylistResolution: Equatable, Sendable {
    /// The body parsed as a station list: one entry per http(s) stream URL,
    /// carrying the playlist's title hint when it had one.
    case stations([RemotePlaylistStation])
    /// The body is an HLS playlist (`#EXT-X-` tags). The pasted URL is itself
    /// the stream; treat it as a single station, not a station list.
    case hlsStream
    /// The body did not parse as a playlist holding stream entries. Treat the
    /// pasted URL as a direct stream and let playback decide.
    case notAPlaylist
}

/// One stream entry lifted from a remote playlist.
public struct RemotePlaylistStation: Equatable, Sendable {
    /// Title hint from `#EXTINF` / `TitleN`, when present and non-empty.
    public let name: String?
    /// The absolute http(s) stream URL, exactly as the playlist wrote it.
    public let streamURL: String

    public init(name: String?, streamURL: String) {
        self.name = name
        self.streamURL = streamURL
    }
}

// MARK: - RemotePlaylistResolver

/// Resolves a pasted playlist URL (`.pls` / `.m3u` / `.m3u8`) into radio
/// stations (phase 27-3): fetch, sniff, parse with the phase 14 readers.
///
/// Callers gate the fetch on `looksLikePlaylist(_:)` first: blindly GETting a
/// pasted URL would download an infinite live stream just to sniff it.
/// Playlist files are small; the request still carries a timeout in case a
/// live stream is mislabelled with a playlist extension.
public struct RemotePlaylistResolver: Sendable {
    private let session: URLSession
    private let log = AppLogger.make(.library)

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Whether `url` should be fetched and parsed rather than streamed:
    /// true for `pls` / `m3u` / `m3u8` path extensions, case-insensitively.
    public static func looksLikePlaylist(_ url: URL) -> Bool {
        ["pls", "m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    /// Fetches `url` and classifies the body. Throws on transport errors and
    /// non-2xx responses; classification itself never throws.
    public func resolve(_ url: URL) async throws -> RemotePlaylistResolution {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw PlaylistIOError.unreadable(url: url, reason: "HTTP \(http.statusCode)")
        }
        let resolution = self.classify(data: data, url: url)
        self.logOutcome(resolution, url: url)
        return resolution
    }

    // MARK: - Classification

    private func classify(data: Data, url: URL) -> RemotePlaylistResolution {
        // HLS first: an `.m3u8` variant ladder is M3U-shaped, so it would
        // otherwise "parse" as an empty station list.
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("#EXT-X-") {
            return .hlsStream
        }

        let format = PlaylistFormat.sniff(data: data, fallback: url.pathExtension)
            ?? PlaylistFormat.fromExtension(url.pathExtension)
        let payload: PlaylistPayload? = switch format {
        case .m3u, .m3u8:
            try? M3UReader.parse(data: data, sourceURL: nil)

        case .pls:
            try? PLSReader.parse(data: data, sourceURL: url)

        default:
            nil
        }
        guard let payload else { return .notAPlaylist }

        let stations = payload.entries.compactMap { entry -> RemotePlaylistStation? in
            guard let entryURL = URL(string: entry.path),
                  let scheme = entryURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            let title = entry.titleHint?.trimmingCharacters(in: .whitespaces)
            return RemotePlaylistStation(
                name: (title?.isEmpty ?? true) ? nil : title,
                streamURL: entry.path
            )
        }
        return stations.isEmpty ? .notAPlaylist : .stations(stations)
    }

    private func logOutcome(_ resolution: RemotePlaylistResolution, url: URL) {
        switch resolution {
        case let .stations(stations):
            self.log.debug("radio.playlist.resolve", ["url": url.absoluteString, "stations": stations.count])

        case .hlsStream:
            self.log.debug("radio.playlist.hls", ["url": url.absoluteString])

        case .notAPlaylist:
            self.log.debug("radio.playlist.miss", ["url": url.absoluteString])
        }
    }
}
