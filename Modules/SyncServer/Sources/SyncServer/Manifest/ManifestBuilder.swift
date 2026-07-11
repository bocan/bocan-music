import Crypto
import Foundation
import Library
import Metadata
import Observability
import Persistence

/// Builds the Phone Sync manifest (sync-protocol.md section 7) from the library.
///
/// The Mac schema does not match the wire shape one-to-one; this builder owns the
/// impedance handling documented in phase 22-5:
/// - `relPath` is derived from `tracks.file_url` relative to a library root (there
///   is no stored relative path and no root foreign key; roots are matched by
///   path prefix);
/// - CUE virtual tracks key off `source_file_url`, not a track id, so a clip
///   resolves its parent by file URL and duplicates the parent's file identity;
/// - a track with no `content_hash` cannot be served and is excluded;
/// - `lyricsHash` is computed from the assembled lyrics document (there is no
///   stored hash);
/// - artist/album names are resolved from their id tables;
/// - ReplayGain is emitted only when a track gain is present.
///
/// Podcasts are added in phase 22-5C.
public struct ManifestBuilder: Sendable {
    private let trackRepository: TrackRepository
    private let albumRepository: AlbumRepository
    private let artistRepository: ArtistRepository
    private let playlistRepository: PlaylistRepository
    private let rootRepository: LibraryRootRepository
    private let lyricsService: LyricsService
    private let smartService: SmartPlaylistService
    private let log = AppLogger.make(.sync)

    public init(database: Database) {
        self.trackRepository = TrackRepository(database: database)
        self.albumRepository = AlbumRepository(database: database)
        self.artistRepository = ArtistRepository(database: database)
        self.playlistRepository = PlaylistRepository(database: database)
        self.rootRepository = LibraryRootRepository(database: database)
        self.lyricsService = LyricsService(database: database, fetcher: nil)
        self.smartService = SmartPlaylistService(database: database)
    }

    func build(
        profile: SyncProfile,
        serverId: String,
        serverName: String,
        generation: Int,
        generatedAt: Date
    ) async throws -> Manifest {
        let allTracks = try await self.trackRepository.fetchAllIncludingDisabled()
        let albums = try await self.albumRepository.fetchAll()
        let artists = try await self.artistRepository.fetchAll()
        let playlists = try await self.playlistRepository.fetchAll()
        let roots = try await self.rootRepository.fetchAll()

        let artistName = Dictionary(uniqueKeysWithValues: artists.compactMap { artist in artist.id.map { ($0, artist.name) } })
        let albumTitle = Dictionary(uniqueKeysWithValues: albums.compactMap { album in album.id.map { ($0, album.title) } })
        let trackByFileURL = Dictionary(allTracks.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        let profileTrackIds = try await self.inProfileTrackIds(profile: profile, allTracks: allTracks, playlists: playlists)

        var manifestTracks = self.buildTracks(
            allTracks: allTracks,
            profileTrackIds: profileTrackIds,
            trackByFileURL: trackByFileURL,
            roots: roots,
            artistName: artistName,
            albumTitle: albumTitle
        )

        // Lyrics hashes are assembled outside the record fetch (best effort; a
        // mid-build change is the next generation's problem, per the spec).
        let includedIds = Set(manifestTracks.map(\.id))
        for index in manifestTracks.indices {
            manifestTracks[index].lyricsHash = try await self.lyricsHash(trackId: manifestTracks[index].id)
        }

        let manifestPlaylists = try await self.buildPlaylists(playlists: playlists, includedTrackIds: includedIds)

        return Manifest(
            protocolVersion: 1,
            serverId: serverId,
            serverName: serverName,
            generation: generation,
            generatedAt: Self.iso8601String(generatedAt),
            tracks: manifestTracks,
            playlists: manifestPlaylists,
            podcasts: [],
            episodes: []
        )
    }

    // MARK: - Tracks

    private func buildTracks(
        allTracks: [Track],
        profileTrackIds: Set<Int64>,
        trackByFileURL: [String: Track],
        roots: [LibraryRoot],
        artistName: [Int64: String],
        albumTitle: [Int64: String]
    ) -> [ManifestTrack] {
        let candidates = allTracks
            .filter { !$0.disabled }
            .filter { $0.id.map { profileTrackIds.contains($0) } ?? false }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }

        var result: [ManifestTrack] = []
        var includedIds: Set<Int64> = []
        var skipped = 0

        // Pass 1: whole-file tracks (so clips can reference them).
        for track in candidates where track.sourceFileURL == nil {
            guard let id = track.id else { continue }
            guard let hash = track.contentHash else { skipped += 1
                continue
            }
            guard let relPath = Self.relPath(for: track.fileURL, roots: roots) else { skipped += 1
                continue
            }
            result.append(self.makeTrack(
                track, id: id, relPath: relPath, size: track.fileSize, sha256: hash,
                format: track.fileFormat, clip: nil, artistName: artistName, albumTitle: albumTitle
            ))
            includedIds.insert(id)
        }

        // Pass 2: CUE virtual tracks, which duplicate their parent's file identity.
        for track in candidates where track.sourceFileURL != nil {
            guard let id = track.id, let sourceURL = track.sourceFileURL else { continue }
            guard
                let source = trackByFileURL[sourceURL],
                let sourceId = source.id,
                includedIds.contains(sourceId),
                let hash = source.contentHash,
                let relPath = Self.relPath(for: source.fileURL, roots: roots) else {
                skipped += 1
                continue
            }
            let clip = ManifestClip(sourceTrackId: sourceId, startMs: track.startOffsetMs ?? 0, endMs: track.endOffsetMs ?? 0)
            result.append(self.makeTrack(
                track, id: id, relPath: relPath, size: source.fileSize, sha256: hash,
                format: source.fileFormat, clip: clip, artistName: artistName, albumTitle: albumTitle
            ))
            includedIds.insert(id)
        }

        if skipped > 0 {
            self.log.debug("manifest.tracks.skipped", ["count": skipped])
        }
        return result.sorted { $0.id < $1.id }
    }

    private func makeTrack(
        _ track: Track,
        id: Int64,
        relPath: String,
        size: Int64,
        sha256: String,
        format: String,
        clip: ManifestClip?,
        artistName: [Int64: String],
        albumTitle: [Int64: String]
    ) -> ManifestTrack {
        ManifestTrack(
            id: id,
            relPath: relPath,
            size: size,
            sha256: sha256,
            format: format,
            durationMs: Int((track.duration * 1000).rounded()),
            title: track.title,
            artist: track.artistID.flatMap { artistName[$0] },
            artistId: track.artistID,
            albumArtist: track.albumArtistID.flatMap { artistName[$0] },
            albumArtistId: track.albumArtistID,
            album: track.albumID.flatMap { albumTitle[$0] },
            albumId: track.albumID,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            year: track.year,
            genre: track.genre,
            composer: track.composer,
            bpm: track.bpm,
            rating: track.rating,
            loved: track.loved,
            sampleRate: track.sampleRate,
            bitDepth: track.bitDepth,
            bitrate: track.bitrate,
            channelCount: track.channelCount,
            isLossless: track.isLossless,
            replayGain: Self.replayGain(track),
            artworkHash: track.coverArtHash,
            lyricsHash: nil,
            clip: clip
        )
    }

    private static func replayGain(_ track: Track) -> ManifestReplayGain? {
        guard let trackGain = track.replaygainTrackGain else { return nil }
        return ManifestReplayGain(
            trackGain: trackGain,
            trackPeak: track.replaygainTrackPeak,
            albumGain: track.replaygainAlbumGain,
            albumPeak: track.replaygainAlbumPeak
        )
    }

    /// Derives the sanitized relative path of a `file://` URL within a library
    /// root, or `nil` if the track is under no known root or the path is unsafe.
    static func relPath(for fileURL: String, roots: [LibraryRoot]) -> String? {
        guard let url = URL(string: fileURL) else { return nil }
        let path = url.path
        for root in roots {
            let prefix = root.path == "/" ? "/" : root.path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            if relative.isEmpty || relative.hasPrefix("/") || relative.contains("..") {
                return nil
            }
            return relative
        }
        return nil
    }

    private func lyricsHash(trackId: Int64) async throws -> String? {
        guard let document = try await self.lyricsService.lyrics(for: trackId) else { return nil }
        let digest = SHA256.hash(data: Data(document.toLRC().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Playlists

    private func buildPlaylists(playlists: [Playlist], includedTrackIds: Set<Int64>) async throws -> [ManifestPlaylist] {
        var result: [ManifestPlaylist] = []
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let trackIds: [Int64] = switch playlist.kind {
            case .folder:
                []
            case .manual:
                try await self.playlistRepository.fetchTrackIDs(playlistID: id)
                    .filter { includedTrackIds.contains($0) }
            case .smart:
                try await self.smartService.tracks(for: id)
                    .compactMap(\.id)
                    .filter { includedTrackIds.contains($0) }
            }
            result.append(ManifestPlaylist(
                id: id,
                name: playlist.name,
                kind: playlist.kind.rawValue,
                parentId: playlist.parentID,
                sortOrder: playlist.sortOrder,
                accentColor: playlist.accentColor,
                // v1: playlist artwork is a local path on the Mac, not a content
                // hash, so no artworkHash is advertised (the phone falls back).
                artworkHash: nil,
                trackIds: trackIds
            ))
        }
        return result
    }

    // MARK: - Profile

    private func inProfileTrackIds(profile: SyncProfile, allTracks: [Track], playlists: [Playlist]) async throws -> Set<Int64> {
        switch profile {
        case .everything:
            return Set(allTracks.compactMap(\.id))
        case let .selected(playlistIds, _):
            var ids: Set<Int64> = []
            for playlistId in playlistIds {
                try await self.gatherPlaylistTracks(playlistId: playlistId, playlists: playlists, into: &ids)
            }
            return ids
        }
    }

    private func gatherPlaylistTracks(playlistId: Int64, playlists: [Playlist], into ids: inout Set<Int64>) async throws {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        switch playlist.kind {
        case .manual:
            try await ids.formUnion(self.playlistRepository.fetchTrackIDs(playlistID: playlistId))
        case .smart:
            try await ids.formUnion(self.smartService.tracks(for: playlistId).compactMap(\.id))
        case .folder:
            for child in playlists where child.parentID == playlistId {
                guard let childId = child.id else { continue }
                try await self.gatherPlaylistTracks(playlistId: childId, playlists: playlists, into: &ids)
            }
        }
    }

    // MARK: - Formatting

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
