import Foundation
import Observability
import Persistence

/// Imports a parsed `PlaylistPayload` into the library, materialising a real
/// playlist row plus track membership for every resolved entry.
public actor PlaylistImportService {
    private let resolver: TrackResolver
    private let playlists: PlaylistService
    private let trackRepo: TrackRepository
    private let log = AppLogger.make(.library)

    public init(resolver: TrackResolver, playlists: PlaylistService, trackRepo: TrackRepository) {
        self.resolver = resolver
        self.playlists = playlists
        self.trackRepo = trackRepo
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
        case .cue: return try await self.importCUESheet(data: data, url: url, parentID: parentID)
        case .itunesXML:
            throw PlaylistIOError.unrecognisedFormat(url: url)
        }
        return try await self.importPayload(payload, parentID: parentID)
    }

    // MARK: - CUE sheet import

    /// Parse a CUE sheet and materialise each TRACK block as a virtual `Track`
    /// row in the database, then group them into a new playlist.
    private func importCUESheet(data: Data, url: URL, parentID: Int64?) async throws -> ImportReport {
        let cueSheet = try CUESheetReader.parse(data: data, sourceURL: url)
        let playlistName = cueSheet.title ?? url.deletingPathExtension().lastPathComponent

        var virtualTrackIDs: [Int64] = []

        for file in cueSheet.files {
            guard let audioURL = file.absoluteURL else {
                self.log.warning("cue.import.noAudioURL", ["cueFile": url.lastPathComponent, "path": file.path])
                continue
            }
            let sourceURLString = audioURL.absoluteString
            let tracks = file.tracks

            for (index, cueTrack) in tracks.enumerated() {
                let startMs = cueTrack.startMs
                let endMs: Int64? = if let explicit = cueTrack.endMs {
                    explicit
                } else if index + 1 < tracks.count {
                    tracks[index + 1].startMs
                } else {
                    nil // last track — play to EOF
                }

                let duration: TimeInterval = if let endMs {
                    TimeInterval(endMs - startMs) / 1000.0
                } else {
                    0.0 // engine will play to decoder EOF
                }

                // Virtual fileURL is unique per CUE track; uses a `?cue=N` suffix
                // so the path component still points at the audio file for scope matching.
                let virtualFileURL = sourceURLString + "?cue=\(cueTrack.number)"

                // Skip if this virtual track was already imported.
                if let existing = try? await trackRepo.fetchOne(fileURL: virtualFileURL), let id = existing.id {
                    virtualTrackIDs.append(id)
                    continue
                }

                let now = Int64(Date().timeIntervalSince1970)
                let track = Track(
                    fileURL: virtualFileURL,
                    duration: duration,
                    title: cueTrack.title,
                    trackNumber: cueTrack.number,
                    isrc: cueTrack.isrc,
                    startOffsetMs: startMs,
                    endOffsetMs: endMs,
                    sourceFileURL: sourceURLString,
                    addedAt: now,
                    updatedAt: now
                )
                let id = try await trackRepo.insert(track)
                virtualTrackIDs.append(id)
            }
        }

        let playlist = try await playlists.create(name: playlistName, parentID: parentID)
        guard let pid = playlist.id else {
            throw PlaylistIOError.lookupFailed(reason: "Created CUE playlist has no id")
        }
        if !virtualTrackIDs.isEmpty {
            try await self.playlists.addTracks(virtualTrackIDs, to: pid, at: nil)
        }

        self.log.info("cue.import", [
            "playlistID": pid,
            "name": playlistName,
            "tracks": virtualTrackIDs.count,
        ])

        let resolution = Resolution(
            matches: virtualTrackIDs.enumerated().map { Resolution.Match(entryIndex: $0.offset, trackID: $0.element) },
            misses: []
        )
        return ImportReport(playlistID: pid, payloadName: playlistName, resolution: resolution)
    }
}
