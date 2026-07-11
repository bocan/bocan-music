import Crypto
import Foundation
import Library
import Metadata
import Observability
import Persistence
import Podcasts

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
    private let podcastRepository: PodcastRepository
    private let episodeRepository: EpisodeRepository
    private let episodeStateRepository: EpisodeStateRepository
    private let lyricsService: LyricsService
    private let smartService: SmartPlaylistService
    private let downloadStore: DownloadStore
    private let log = AppLogger.make(.sync)

    /// - Parameter downloadRoot: overrides the podcast Downloads directory (tests
    ///   only); production uses the default Application Support location.
    public init(database: Database, downloadRoot: URL? = nil) {
        self.trackRepository = TrackRepository(database: database)
        self.albumRepository = AlbumRepository(database: database)
        self.artistRepository = ArtistRepository(database: database)
        self.playlistRepository = PlaylistRepository(database: database)
        self.rootRepository = LibraryRootRepository(database: database)
        self.podcastRepository = PodcastRepository(database: database)
        self.episodeRepository = EpisodeRepository(database: database)
        self.episodeStateRepository = EpisodeStateRepository(database: database)
        self.lyricsService = LyricsService(database: database, fetcher: nil)
        self.smartService = SmartPlaylistService(database: database)
        self.downloadStore = DownloadStore(root: downloadRoot)
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
        let podcasts = try await self.buildPodcasts(profile: profile)

        return Manifest(
            protocolVersion: 1,
            serverId: serverId,
            serverName: serverName,
            generation: generation,
            generatedAt: Self.iso8601String(generatedAt),
            tracks: manifestTracks,
            playlists: manifestPlaylists,
            podcasts: podcasts.shows,
            episodes: podcasts.episodes
        )
    }

    // MARK: - Podcasts

    private func buildPodcasts(profile: SyncProfile) async throws -> (shows: [ManifestPodcast], episodes: [ManifestEpisode]) {
        guard profile.includesPodcasts else { return ([], []) }

        let downloaded = try await self.episodeStateRepository.fetchByDownloadState([.downloaded])
        let statesByPodcast = Dictionary(grouping: downloaded, by: \.podcastID)
        guard !statesByPodcast.isEmpty else { return ([], []) }

        var shows: [ManifestPodcast] = []
        var episodes: [ManifestEpisode] = []

        for podcast in try await self.podcastRepository.fetchAllSubscribed() {
            guard let podcastId = podcast.id, let states = statesByPodcast[podcastId] else { continue }
            let contentByGUID = try await Dictionary(
                self.episodeRepository.fetchForPodcast(podcastID: podcastId).map { ($0.guid, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var addedAny = false
            for state in states {
                guard let content = contentByGUID[state.guid] else { continue }
                guard let episode = self.makeEpisode(content: content, state: state, podcastId: podcastId) else { continue }
                episodes.append(episode)
                addedAny = true
            }
            if addedAny {
                shows.append(ManifestPodcast(
                    id: podcastId,
                    title: podcast.title,
                    author: podcast.author,
                    descriptionHtml: podcast.description,
                    // v1: podcast artwork is a local path, not a content hash.
                    artworkHash: nil,
                    playbackSpeed: podcast.playbackSpeed
                ))
            }
        }

        return (shows.sorted { $0.id < $1.id }, episodes.sorted { $0.id < $1.id })
    }

    private func makeEpisode(content: PodcastEpisode, state: PodcastEpisodeState, podcastId: Int64) -> ManifestEpisode? {
        let fileURL = self.downloadStore.fileURL(podcastID: podcastId, guid: content.guid, mime: content.audioMIME)
        // The hash is stored at download time (M032); fall back to hashing the
        // file for episodes downloaded before that migration.
        let sha256: String
        if let stored = state.contentHash {
            sha256 = stored
        } else if let computed = Self.hashFile(fileURL) {
            sha256 = computed
        } else {
            // The download is gone; without the bytes we cannot serve or hash it.
            return nil
        }
        let idHash = fileURL.deletingPathExtension().lastPathComponent
        let size = state.downloadBytes ?? Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return ManifestEpisode(
            id: idHash,
            podcastId: podcastId,
            guid: content.guid,
            title: content.title,
            publishedAt: content.publishedAt.map { Self.iso8601String(Date(timeIntervalSince1970: $0)) },
            durationMs: content.duration.map { Int(($0 * 1000).rounded()) },
            descriptionHtml: content.descriptionHTML,
            relPath: "Podcasts/\(podcastId)/\(fileURL.lastPathComponent)",
            size: size,
            sha256: sha256,
            hasChapters: content.chaptersURL != nil,
            playPositionMs: Int((state.playPosition * 1000).rounded()),
            playState: state.playState.rawValue
        )
    }

    /// Streams a file through SHA-256 without loading it whole into memory.
    private static func hashFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

// MARK: - Size estimate

public extension ManifestBuilder {
    /// The on-disk cost of a sync profile, for the Settings size estimate. Summed
    /// from the manifest the profile produces so it matches what would actually
    /// sync (including CUE clips and podcast episodes).
    struct SizeEstimate: Sendable, Equatable {
        public let bytes: Int64
        public let trackCount: Int
        public let episodeCount: Int
    }

    func sizeEstimate(for profile: SyncProfile) async throws -> SizeEstimate {
        let manifest = try await self.build(
            profile: profile,
            serverId: "estimate",
            serverName: "",
            generation: 0,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let trackBytes = manifest.tracks.reduce(Int64(0)) { $0 + $1.size }
        let episodeBytes = manifest.episodes.reduce(Int64(0)) { $0 + $1.size }
        return SizeEstimate(
            bytes: trackBytes + episodeBytes,
            trackCount: manifest.tracks.count,
            episodeCount: manifest.episodes.count
        )
    }
}
