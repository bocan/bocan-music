import Foundation
import Metadata
import Observability
import Persistence

/// Converts ``TrackTags`` into the Persistence layer's artist/album/track records.
///
/// All write operations are performed inside a single DB transaction per file.
actor TrackImporter {
    // MARK: - Dependencies

    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let trackRepo: TrackRepository
    private let lyricsRepo: LyricsRepository
    private let coverArtCache: CoverArtCache
    private let log = AppLogger.make(.library)

    // MARK: - Init

    init(
        artistRepo: ArtistRepository,
        albumRepo: AlbumRepository,
        trackRepo: TrackRepository,
        lyricsRepo: LyricsRepository,
        coverArtCache: CoverArtCache
    ) {
        self.artistRepo = artistRepo
        self.albumRepo = albumRepo
        self.trackRepo = trackRepo
        self.lyricsRepo = lyricsRepo
        self.coverArtCache = coverArtCache
    }

    // MARK: - Import

    /// Inserts or updates a track from `tags` at `url`.
    ///
    /// - Returns: The database row ID of the upserted track.
    @discardableResult
    func importTrack(
        url: URL,
        bookmark: Data?,
        tags: TrackTags,
        fileMtime: Int64,
        fileSize: Int64
    ) async throws -> Int64 {
        // Artist
        let artistName = tags.artist ?? "Unknown Artist"
        let artist = try await artistRepo.findOrCreate(name: artistName)

        // Album artist (may differ from track artist)
        let albumArtistName = tags.albumArtist ?? artistName
        let albumArtist = albumArtistName == artistName
            ? artist
            : try await self.artistRepo.findOrCreate(name: albumArtistName)

        // Album
        let albumTitle = tags.album ?? "Unknown Album"
        let album = try await albumRepo.findOrCreate(
            title: albumTitle,
            albumArtistID: albumArtist.id
        )

        // Cover art
        let coverArt = try await coverArtCache.persist(tags.coverArt)

        // Link cover art to the album if not already set
        if album.coverArtPath == nil, let art = coverArt {
            var updated = album
            updated.coverArtHash = art.hash
            updated.coverArtPath = art.path
            try await self.albumRepo.update(updated)
        }

        // Normalised file URL string
        let fileURLString = url.absoluteString
            .precomposedStringWithCanonicalMapping

        // Sort key: "DD.TTTT"
        let disc = tags.discNumber ?? 0
        let track = tags.trackNumber ?? 0
        let sortKey = String(format: "%02d.%04d", disc, track)

        let now = Int64(Date.now.timeIntervalSince1970)

        // Fetch existing to preserve play stats and user_edited flag
        let existing = try await trackRepo.fetchOne(fileURL: fileURLString)

        // If the user has manually edited tags, skip overwriting them
        if let ex = existing, ex.userEdited {
            // Still update file-level fields
            var updated = ex
            updated.fileSize = fileSize
            updated.fileMtime = fileMtime
            updated.fileBookmark = bookmark
            updated.updatedAt = now
            updated.disabled = false
            try await self.trackRepo.update(updated)
            self.log.debug("track.user_edited_skip", ["url": url.lastPathComponent])
            return ex.id ?? 0
        }

        var track_ = Track(
            id: existing?.id,
            fileURL: fileURLString,
            fileBookmark: bookmark,
            fileSize: fileSize,
            fileMtime: fileMtime,
            fileFormat: url.pathExtension.lowercased(),
            duration: tags.duration,
            sampleRate: tags.sampleRate,
            bitDepth: tags.bitDepth,
            bitrate: tags.bitrate,
            channelCount: tags.channels,
            isLossless: self.isLossless(format: url.pathExtension.lowercased()),
            title: tags.title,
            artistID: artist.id,
            albumArtistID: albumArtist.id,
            albumID: album.id,
            trackNumber: tags.trackNumber,
            trackTotal: tags.trackTotal,
            discNumber: tags.discNumber,
            discTotal: tags.discTotal,
            year: tags.year,
            genre: tags.genre,
            composer: tags.composer,
            bpm: tags.bpm,
            key: tags.key,
            isrc: tags.isrc,
            musicbrainzTrackID: tags.musicbrainzTrackID,
            musicbrainzRecordingID: tags.musicbrainzRecordingID,
            musicbrainzAlbumArtistID: tags.musicbrainzAlbumArtistID,
            musicbrainzReleaseID: tags.musicbrainzReleaseID,
            musicbrainzReleaseGroupID: tags.musicbrainzReleaseGroupID,
            replaygainTrackGain: tags.replayGain.trackGain,
            replaygainTrackPeak: tags.replayGain.trackPeak,
            replaygainAlbumGain: tags.replayGain.albumGain,
            replaygainAlbumPeak: tags.replayGain.albumPeak,
            playCount: existing?.playCount ?? 0,
            skipCount: existing?.skipCount ?? 0,
            lastPlayedAt: existing?.lastPlayedAt,
            rating: existing?.rating ?? 0,
            loved: existing?.loved ?? false,
            excludedFromShuffle: existing?.excludedFromShuffle ?? false,
            playDurationTotal: existing?.playDurationTotal ?? 0,
            filePathDisplay: url.path,
            disabled: false,
            userEdited: false,
            albumTrackSortKey: sortKey,
            coverArtHash: coverArt?.hash,
            addedAt: existing?.addedAt ?? now,
            updatedAt: now
        )

        let id = try await trackRepo.upsert(track_)
        track_.id = id

        // Persist lyrics if present
        if let lyricsText = tags.lyrics, !lyricsText.isEmpty {
            let lines = LRCParser.parse(lyricsText)
            let isLRC = lines.contains { $0.timestamp != nil }
            let lyricsRecord = Lyrics(
                trackID: id,
                lyricsText: lyricsText,
                isSynced: isLRC,
                source: "embedded"
            )
            try await lyricsRepo.save(lyricsRecord)
        }

        self.log.debug("track.import", ["url": url.lastPathComponent, "id": id])
        return id
    }

    // MARK: - Helpers

    private func isLossless(format: String) -> Bool {
        ["flac", "wav", "aiff", "aif", "alac", "wv", "ape", "dsf", "dff"].contains(format)
    }
}
