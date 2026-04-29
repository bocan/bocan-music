import Foundation
import GRDB
import Observability
import Persistence

/// Exports library playlists to disk.
public actor PlaylistExportService {
    private let database: Persistence.Database
    private let log = AppLogger.make(.library)

    public init(database: Persistence.Database) {
        self.database = database
    }

    public struct ExportRequest: Sendable {
        public let playlistID: Int64
        public let destination: URL
        public let format: PlaylistFormat
        public let pathMode: PathMode
        public init(playlistID: Int64, destination: URL, format: PlaylistFormat, pathMode: PathMode) {
            self.playlistID = playlistID
            self.destination = destination
            self.format = format
            self.pathMode = pathMode
        }
    }

    public func export(_ request: ExportRequest) async throws {
        guard request.format.isExportable else {
            throw PlaylistIOError.writeFailed(
                url: request.destination,
                underlying: "Format \(request.format.rawValue) does not support export"
            )
        }
        let payload = try await self.buildPayload(playlistID: request.playlistID)
        try self.write(payload: payload, format: request.format, pathMode: request.pathMode, to: request.destination)
        self.log.info(
            "playlist.export",
            [
                "playlist_id": request.playlistID,
                "format": request.format.rawValue,
                "entries": payload.entries.count,
                "destination": request.destination.lastPathComponent,
            ]
        )
    }

    /// Export a smart-playlist snapshot by passing pre-resolved `trackIDs`.
    public func exportSmart(
        name: String,
        trackIDs: [Int64],
        destination: URL,
        format: PlaylistFormat,
        pathMode: PathMode
    ) async throws {
        guard format.isExportable else {
            throw PlaylistIOError.writeFailed(
                url: destination,
                underlying: "Format \(format.rawValue) does not support export"
            )
        }
        let payload = try await self.buildSmartPayload(name: name, trackIDs: trackIDs)
        try self.write(payload: payload, format: format, pathMode: pathMode, to: destination)
    }

    // MARK: - Payload builder

    public func buildPayload(playlistID: Int64) async throws -> PlaylistPayload {
        try await self.database.read { db in
            guard let playlist = try Playlist.fetchOne(db, key: playlistID) else {
                throw PlaylistIOError.lookupFailed(reason: "Playlist \(playlistID) not found")
            }
            let memberSQL = """
            SELECT t.* FROM tracks t
            INNER JOIN playlist_tracks pt ON pt.track_id = t.id
            WHERE pt.playlist_id = ?
            ORDER BY pt.position
            """
            let tracks = try Track.fetchAll(db, sql: memberSQL, arguments: [playlistID])
            let entries = tracks.map { Self.makeEntry(track: $0, db: db) }
            return PlaylistPayload(name: playlist.name, entries: entries)
        }
    }

    public func buildSmartPayload(name: String, trackIDs: [Int64]) async throws -> PlaylistPayload {
        try await self.database.read { db in
            var entries: [PlaylistPayload.Entry] = []
            entries.reserveCapacity(trackIDs.count)
            for tid in trackIDs {
                if let t = try Track.fetchOne(db, key: tid) {
                    entries.append(Self.makeEntry(track: t, db: db))
                }
            }
            return PlaylistPayload(name: name, entries: entries)
        }
    }

    private static func makeEntry(track: Track, db: GRDB.Database) -> PlaylistPayload.Entry {
        let absolute: URL? = {
            if let u = URL(string: track.fileURL), u.scheme != nil {
                return u
            }
            return URL(fileURLWithPath: track.fileURL)
        }()
        let artist = try? Self.lookup(table: "artists", id: track.artistID, column: "name", db: db)
        let album = try? Self.lookup(table: "albums", id: track.albumID, column: "title", db: db)
        return PlaylistPayload.Entry(
            path: track.fileURL,
            absoluteURL: absolute,
            durationHint: track.duration,
            titleHint: track.title,
            artistHint: artist ?? nil,
            albumHint: album ?? nil
        )
    }

    private static func lookup(table: String, id: Int64?, column: String, db: GRDB.Database) throws -> String? {
        guard let id else { return nil }
        return try String.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id])
    }

    // MARK: - Serialise + write

    public nonisolated func serialise(
        _ payload: PlaylistPayload,
        format: PlaylistFormat,
        pathMode: PathMode
    ) -> String {
        switch format {
        case .m3u, .m3u8:
            M3UWriter.write(
                payload,
                options: M3UWriter.Options(pathMode: pathMode, includeExtArt: true, includeExtAlb: true)
            )
        case .pls:
            PLSWriter.write(payload, options: PLSWriter.Options(pathMode: pathMode))
        case .xspf:
            XSPFWriter.write(payload, options: XSPFWriter.Options(pathMode: pathMode))
        case .cue, .itunesXML:
            ""
        }
    }

    private func write(
        payload: PlaylistPayload,
        format: PlaylistFormat,
        pathMode: PathMode,
        to destination: URL
    ) throws {
        let body = self.serialise(payload, format: format, pathMode: pathMode)
        guard let data = body.data(using: .utf8) else {
            throw PlaylistIOError.writeFailed(url: destination, underlying: "UTF-8 encode failed")
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw PlaylistIOError.writeFailed(url: destination, underlying: String(describing: error))
        }
    }
}
