import Crypto
import Foundation
import Library
import Metadata
import Observability
import Persistence
import Podcasts

/// The paired-only file endpoints (sync-protocol.md section 6). Every file is
/// resolved by id or hash through the database and its stored location; the
/// request never names a filesystem path, so directory traversal is structurally
/// impossible. Track and episode bodies are streamed (never buffered whole);
/// artwork and lyrics are small and buffered.
///
/// v1 limitations, driven by the data model (not the wire contract):
/// - `/v1/chapters` returns 404: chapters are fetched from the network on demand,
///   with no cached store to serve, and a serving handler must not make outbound
///   requests. Caching chapters is a Podcasts-module follow-up.
/// - Episode `If-Match`/`ETag` is not emitted: episodes have no stored content
///   hash (tracks store `content_hash`). Range resume is supported; change
///   detection falls back to the manifest generation counter and the client's
///   final SHA-256 verify. Storing an episode hash at download time is the fix.
struct FileServing {
    private let trackRepository: TrackRepository
    private let episodeRepository: EpisodeRepository
    private let episodeStateRepository: EpisodeStateRepository
    private let coverArtRepository: CoverArtRepository
    private let playlistRepository: PlaylistRepository
    private let profileRepository: SyncProfileRepository
    private let smartService: SmartPlaylistService
    private let lyricsService: LyricsService
    private let downloadStore: DownloadStore
    private let log = AppLogger.make(.sync)

    init(database: Database, downloadRoot: URL? = nil) {
        self.trackRepository = TrackRepository(database: database)
        self.episodeRepository = EpisodeRepository(database: database)
        self.episodeStateRepository = EpisodeStateRepository(database: database)
        self.coverArtRepository = CoverArtRepository(database: database)
        self.playlistRepository = PlaylistRepository(database: database)
        self.profileRepository = SyncProfileRepository(database: database)
        self.smartService = SmartPlaylistService(database: database)
        self.lyricsService = LyricsService(database: database, fetcher: nil)
        self.downloadStore = DownloadStore(root: downloadRoot)
    }

    func routes() -> [Router.Route] {
        [
            Router.Route("GET", "/v1/file/track/{trackId}", auth: .paired) { request, match in
                await self.track(request, match)
            },
            Router.Route("GET", "/v1/file/episode/{episodeId}", auth: .paired) { request, match in
                await self.episode(request, match)
            },
            Router.Route("GET", "/v1/artwork/{hash}", auth: .paired) { _, match in
                await self.artwork(match)
            },
            Router.Route("GET", "/v1/lyrics/{trackId}", auth: .paired) { _, match in
                await self.lyrics(match)
            },
            Router.Route("GET", "/v1/chapters/{episodeId}", auth: .paired) { _, _ in
                Self.notFound
            },
        ]
    }

    // MARK: - Track audio

    private func track(_ request: HttpRequest, _ match: Router.RouteMatch) async -> HttpResponse {
        guard let idString = match.parameters["trackId"], let trackId = Int64(idString) else {
            return Self.notFound
        }
        let track: Track
        do {
            track = try await self.trackRepository.fetch(id: trackId)
        } catch {
            return Self.notFound
        }
        guard !track.disabled else { return Self.notFound }

        do {
            guard try await self.isTrackInProfile(trackId) else { return Self.notFound }
        } catch {
            return Self.serverError
        }

        // If-Match compares the stored content hash, so reject a stale request
        // before touching the file.
        if let ifMatch = request.header("if-match"), let hash = track.contentHash, ifMatch != hash {
            return .error(.notFound, message: "Precondition failed", status: 412)
        }

        guard let bookmark = track.fileBookmark else {
            self.log.error("file.track.no_bookmark", ["id": trackId])
            return Self.notFound
        }

        let size: Int64
        do {
            size = try await SecurityScope.withAccess(bookmark) { url in try Self.fileSize(url) }
        } catch {
            self.log.error("file.track.stale_bookmark", ["id": trackId, "error": String(reflecting: error)])
            return Self.notFound
        }

        var headers: [String: String] = [
            "content-type": Self.audioMIME(track.fileFormat),
            "accept-ranges": "bytes",
        ]
        if let hash = track.contentHash { headers["etag"] = hash }

        switch Self.resolveRange(request, totalSize: size) {
        case .unsatisfiable:
            return .error(.notFound, message: "Range not satisfiable", status: 416)
        case let .full(fullSize):
            return .streamed(status: 200, headers: headers, length: Int(fullSize)) { write in
                try await SecurityScope.withAccess(bookmark) { url in
                    try await Self.streamFile(url, offset: 0, length: fullSize, write: write)
                }
            }
        case let .partial(start, length, contentRange):
            headers["content-range"] = contentRange
            return .streamed(status: 206, headers: headers, length: Int(length)) { write in
                try await SecurityScope.withAccess(bookmark) { url in
                    try await Self.streamFile(url, offset: start, length: length, write: write)
                }
            }
        }
    }

    // MARK: - Episode audio

    private func episode(_ request: HttpRequest, _ match: Router.RouteMatch) async -> HttpResponse {
        guard let episodeIdHash = match.parameters["episodeId"] else { return Self.notFound }
        do {
            guard await self.profileIncludesPodcasts() else { return Self.notFound }
            let downloaded = try await self.episodeStateRepository.fetchByDownloadState([.downloaded])
            guard let state = downloaded.first(where: { Self.guidHash($0.guid) == episodeIdHash }) else {
                return Self.notFound
            }
            guard let content = try await self.episodeRepository.fetchByGUID(podcastID: state.podcastID, guid: state.guid) else {
                return Self.notFound
            }

            let fileURL = self.downloadStore.fileURL(podcastID: state.podcastID, guid: state.guid, mime: content.audioMIME)
            let size: Int64
            do {
                size = try Self.fileSize(fileURL)
            } catch {
                self.log.error("file.episode.missing", ["id": episodeIdHash])
                return Self.notFound
            }

            let headers = ["content-type": Self.audioMIME(content.audioMIME ?? ""), "accept-ranges": "bytes"]
            switch Self.resolveRange(request, totalSize: size) {
            case .unsatisfiable:
                return .error(.notFound, message: "Range not satisfiable", status: 416)
            case let .full(fullSize):
                return .streamed(status: 200, headers: headers, length: Int(fullSize)) { write in
                    try await Self.streamFile(fileURL, offset: 0, length: fullSize, write: write)
                }
            case let .partial(start, length, contentRange):
                var rangeHeaders = headers
                rangeHeaders["content-range"] = contentRange
                return .streamed(status: 206, headers: rangeHeaders, length: Int(length)) { write in
                    try await Self.streamFile(fileURL, offset: start, length: length, write: write)
                }
            }
        } catch {
            self.log.error("file.episode.failed", ["error": String(reflecting: error)])
            return Self.serverError
        }
    }

    // MARK: - Artwork

    private func artwork(_ match: Router.RouteMatch) async -> HttpResponse {
        guard let hash = match.parameters["hash"] else { return Self.notFound }
        do {
            guard let art = try await self.coverArtRepository.fetch(hash: hash) else { return Self.notFound }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: art.path))
            } catch {
                self.log.error("file.artwork.missing", ["hash": hash])
                return Self.notFound
            }
            let headers = [
                "content-type": Self.imageMIME(art.format),
                "etag": hash,
                "cache-control": "public, max-age=31536000, immutable",
            ]
            return HttpResponse(status: 200, headers: headers, body: data)
        } catch {
            return Self.serverError
        }
    }

    // MARK: - Lyrics

    private struct LyricsPayload: Encodable {
        let trackId: Int64
        let kind: String
        let text: String
    }

    private func lyrics(_ match: Router.RouteMatch) async -> HttpResponse {
        guard let idString = match.parameters["trackId"], let trackId = Int64(idString) else {
            return Self.notFound
        }
        do {
            guard let document = try await self.lyricsService.lyrics(for: trackId) else { return Self.notFound }
            let kind = switch document {
            case .synced: "synced"
            case .unsynced: "unsynced"
            }
            // The same serialization the manifest hashed for lyricsHash.
            let payload = LyricsPayload(trackId: trackId, kind: kind, text: document.toLRC())
            return try .json(data: JSONEncoder().encode(payload))
        } catch {
            return Self.serverError
        }
    }

    // MARK: - Profile filtering (keep in sync with ManifestBuilder)

    private func loadProfile() async -> SyncProfile {
        await ManifestRoutes.loadProfile(self.profileRepository)
    }

    private func profileIncludesPodcasts() async -> Bool {
        await self.loadProfile().includesPodcasts
    }

    private func isTrackInProfile(_ trackId: Int64) async throws -> Bool {
        switch await self.loadProfile() {
        case .everything:
            return true
        case let .selected(playlistIds, _):
            let playlists = try await self.playlistRepository.fetchAll()
            var ids: Set<Int64> = []
            for playlistId in playlistIds {
                try await self.gatherPlaylistTracks(playlistId, playlists: playlists, into: &ids)
            }
            return ids.contains(trackId)
        }
    }

    private func gatherPlaylistTracks(_ playlistId: Int64, playlists: [Playlist], into ids: inout Set<Int64>) async throws {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        switch playlist.kind {
        case .manual:
            try await ids.formUnion(self.playlistRepository.fetchTrackIDs(playlistID: playlistId))
        case .smart:
            try await ids.formUnion(self.smartService.tracks(for: playlistId).compactMap(\.id))
        case .folder:
            for child in playlists where child.parentID == playlistId {
                guard let childId = child.id else { continue }
                try await self.gatherPlaylistTracks(childId, playlists: playlists, into: &ids)
            }
        }
    }

    // MARK: - Helpers

    private static var notFound: HttpResponse {
        .error(.notFound, message: "Not found", status: 404)
    }

    private static var serverError: HttpResponse {
        .error(.internal, message: "Error", status: 500)
    }

    private static func guidHash(_ guid: String) -> String {
        String(SHA256.hash(data: Data(guid.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// A resolved `Range` request against a file of `totalSize` bytes.
    private enum RangeResolution {
        case full(size: Int64)
        case partial(start: Int64, length: Int64, contentRange: String)
        case unsatisfiable
    }

    private static func resolveRange(_ request: HttpRequest, totalSize: Int64) -> RangeResolution {
        guard let header = request.header("range"), header.hasPrefix("bytes=") else {
            return .full(size: totalSize)
        }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startPart = parts.first, let start = Int64(startPart) else {
            return .full(size: totalSize)
        }
        guard start >= 0, start < totalSize else { return .unsatisfiable }
        var end = totalSize - 1
        if parts.count == 2, !parts[1].isEmpty, let explicitEnd = Int64(parts[1]) {
            end = min(explicitEnd, totalSize - 1)
        }
        guard end >= start else { return .unsatisfiable }
        return .partial(start: start, length: end - start + 1, contentRange: "bytes \(start)-\(end)/\(totalSize)")
    }

    private static func streamFile(
        _ url: URL,
        offset: Int64,
        length: Int64,
        write: @Sendable (Data) async throws -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkSize = Int(min(remaining, 1 << 20))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try await write(chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private static func audioMIME(_ format: String) -> String {
        switch format.lowercased() {
        case "flac": "audio/flac"
        case "mp3", "audio/mpeg": "audio/mpeg"
        case "m4a", "aac", "mp4", "audio/mp4": "audio/mp4"
        case "ogg", "oga": "audio/ogg"
        case "opus": "audio/opus"
        case "wav": "audio/wav"
        case "aiff", "aif": "audio/aiff"
        default: "application/octet-stream"
        }
    }

    private static func imageMIME(_ format: String?) -> String {
        switch format?.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }
}
