import Foundation
import Observability
import Persistence

/// Imports a parsed `PlaylistPayload` into the library, materialising a real
/// playlist row plus track membership for every resolved entry.
public actor PlaylistImportService {
    private let resolver: TrackResolver
    private let playlists: PlaylistService
    private let log = AppLogger.make(.library)

    public init(resolver: TrackResolver, playlists: PlaylistService) {
        self.resolver = resolver
        self.playlists = playlists
    }

    public struct ImportReport: Sendable {
        public let playlistID: Int64
        public let payloadName: String
        public let resolution: Resolution
        public init(playlistID: Int64, payloadName: String, resolution: Resolution) {
            self.playlistID = playlistID
            self.payloadName = payloadName
            self.resolution = resolution
        }
    }

    /// Imports `payload` as a new manual playlist under `parentID`.
    public func importPayload(
        _ payload: PlaylistPayload,
        parentID: Int64? = nil,
        tolerance: TimeInterval = 2.0
    ) async throws -> ImportReport {
        let resolution = await self.resolver.resolve(payload, tolerance: tolerance)
        let playlist = try await self.playlists.create(name: payload.name, parentID: parentID)
        guard let pid = playlist.id else {
            throw PlaylistIOError.lookupFailed(reason: "Created playlist has no id")
        }
        // Add resolved track ids in the order they appeared.
        let orderedIDs = resolution.matches
            .sorted { $0.entryIndex < $1.entryIndex }
            .map(\.trackID)
        if !orderedIDs.isEmpty {
            try await self.playlists.addTracks(orderedIDs, to: pid, at: nil)
        }
        self.log.info(
            "playlist.import",
            [
                "playlist_id": pid,
                "name": payload.name,
                "matched": resolution.matches.count,
                "missed": resolution.misses.count,
            ]
        )
        return ImportReport(playlistID: pid, payloadName: payload.name, resolution: resolution)
    }

    // MARK: - Format-specific entry points

    public func importFile(at url: URL, parentID: Int64? = nil) async throws -> ImportReport {
        let data = try Data(contentsOf: url)
        let format = PlaylistFormat.sniff(data: data, fallback: url.pathExtension) ??
            PlaylistFormat.fromExtension(url.pathExtension) ?? .m3u
        let payload: PlaylistPayload
        switch format {
        case .m3u, .m3u8: payload = try M3UReader.parse(data: data, sourceURL: url)
        case .pls: payload = try PLSReader.parse(data: data, sourceURL: url)
        case .xspf: payload = try XSPFReader.parse(data: data, sourceURL: url)
        case .cue, .itunesXML:
            throw PlaylistIOError.unrecognisedFormat(url: url)
        }
        return try await self.importPayload(payload, parentID: parentID)
    }
}
