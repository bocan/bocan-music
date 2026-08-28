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
        // Artist (may be multi-valued in Vorbis / ID3v2.4 — primary value
        // becomes the artists.name FK target; the joined string lands in
        // tracks.title via the importer's title field for display, while the
        // full list is preserved in tracks.extended_tags JSON below).
        let artistValues = tags.extendedTags["ARTIST"] ?? []
        let primaryArtist = artistValues.first ?? tags.artist ?? "Unknown Artist"
        let artistName = primaryArtist
        let artist = try await artistRepo.findOrCreate(
            name: artistName,
            sortName: tags.sortArtist,
            musicbrainzID: tags.musicbrainzArtistID
        )

        // Album artist (may differ from track artist). Prefer an explicit
        // ALBUMARTIST tag. With none, fall back to the track artist — EXCEPT
        // for compilations, which group under a single "Various Artists" album
        // (nil album artist). Without this a multi-artist compilation with no
        // album-artist tag splits into one album per track artist (#362).
        let albumArtistValues = tags.extendedTags["ALBUMARTIST"] ?? []
        let explicitAlbumArtist = (albumArtistValues.first ?? tags.albumArtist)
            .flatMap { $0.isEmpty ? nil : $0 }
        let albumArtistID: Int64?
        if let explicitAlbumArtist {
            let albumArtist = explicitAlbumArtist == artistName
                ? artist
                : try await self.artistRepo.findOrCreate(
                    name: explicitAlbumArtist,
                    sortName: tags.sortAlbumArtist,
                    musicbrainzID: tags.musicbrainzAlbumArtistID
                )
            albumArtistID = albumArtist.id
        } else if tags.isCompilation {
            albumArtistID = nil // Various Artists
        } else {
            albumArtistID = artist.id
        }

        // Album
        let albumTitle = tags.album ?? "Unknown Album"
        let album = try await albumRepo.findOrCreate(
            title: albumTitle,
            albumArtistID: albumArtistID
        )

        // Cover art. Embedded art always wins; when the file carries none and
        // the album has no art yet, fall back to a sidecar image in the
        // track's folder (cover.jpg / folder.png / …, #388). The album-art
        // guard doubles as a memo: once the first artless track links the
        // sidecar, later tracks in the folder skip the directory listing.
        var coverArt = try await coverArtCache.persist(tags.coverArt, source: "embedded")
        if coverArt == nil, album.coverArtHash == nil {
            coverArt = await self.persistSidecarArt(besideTrackAt: url)
        }

        // Link cover art to the album. We always write if the album is
        // missing the link (hash or path) so previously-unlinked albums heal
        // on the next scan.  We skip when the album already points to the
        // same hash to avoid needless writes.
        if let art = coverArt, album.coverArtHash != art.hash || album.coverArtPath == nil {
            if let albumID = album.id {
                try await self.albumRepo.setCoverArt(
                    albumID: albumID,
                    hash: art.hash,
                    path: art.path
                )
            }
        }

        // Propagate the release year from track tags to the album row when the
        // track supplies a year that differs from what's already stored. This
        // handles both newly-created album rows (year is nil) and albums whose
        // year was corrected in the tags between scans.
        if let trackYear = tags.year, album.year != trackYear, let albumID = album.id {
            try await self.albumRepo.setYear(albumID: albumID, year: trackYear)
        }

        // Same for the MusicBrainz release type (#403): last tagged track
        // wins, which only matters for an album mixed from differently typed
        // releases.
        if let kind = tags.releaseType, !kind.isEmpty, album.releaseType != kind, let albumID = album.id {
            try await self.albumRepo.setReleaseType(albumID: albumID, releaseType: kind)
        }

        // Normalised file URL string
        let fileURLString = url.absoluteString
            .precomposedStringWithCanonicalMapping

        // Sort key: "DD.TTTT"
        let disc = tags.discNumber ?? 0
        let track = tags.trackNumber ?? 0
        let sortKey = String(format: "%02d.%04d", disc, track)

        let now = Int64(Date.now.timeIntervalSince1970)

        // Serialise the full TagLib PropertyMap to JSON for persistence in
        // tracks.extended_tags. Stable key order keeps the column free of
        // gratuitous diffs across rescans.
        let extendedTagsJSON: String? = self.encodeExtendedTags(tags.extendedTags)

        // Fetch existing to preserve play stats and user_edited flag
        let existing = try await trackRepo.fetchOne(fileURL: fileURLString)

        // Provenance verdicts (ADR-075) describe the audio bytes, so they
        // survive rescans of an unchanged file and are nulled the moment the
        // file itself changed. In-app tag edits stamp file_mtime after the
        // rewrite (EditTransaction), so those keep their verdicts too.
        let audioUnchanged = existing?.fileMtime == fileMtime

        // If the user has manually edited tags, skip overwriting them
        if let ex = existing, ex.userEdited {
            // Still update file-level fields, including the audio
            // properties: those come from the container, not from tags, so
            // a user edit never owns them and a full rescan must be able to
            // backfill them (#405).
            var updated = ex
            updated.fileSize = fileSize
            updated.fileMtime = fileMtime
            updated.fileBookmark = bookmark
            updated.duration = tags.duration
            updated.sampleRate = tags.sampleRate
            updated.bitDepth = tags.bitDepth
            updated.bitrate = tags.bitrate
            updated.channelCount = tags.channels
            updated.updatedAt = now
            updated.disabled = false
            if !audioUnchanged {
                updated.clearProvenance()
            }
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
            albumArtistID: albumArtistID,
            albumID: album.id,
            trackNumber: tags.trackNumber,
            trackTotal: tags.trackTotal,
            discNumber: tags.discNumber,
            discTotal: tags.discTotal,
            year: tags.year,
            yearText: tags.dateText,
            genre: tags.genre,
            composer: tags.composer,
            bpm: tags.bpm,
            key: tags.key,
            isrc: tags.isrc,
            musicbrainzTrackID: tags.musicbrainzTrackID,
            musicbrainzRecordingID: tags.musicbrainzRecordingID,
            musicbrainzArtistID: tags.musicbrainzArtistID,
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
            extendedTags: extendedTagsJSON,
            addedAt: existing?.addedAt ?? now,
            updatedAt: now
        )

        // App-computed and user-owned state must survive a rescan (#423);
        // none of it comes from tags. AcoustID results identify the
        // recording, which a retag or re-encode does not change; skip-after
        // is a user setting; ReplayGain keeps the computed value unless the
        // file now carries a tag. Assigned after construction because the
        // initializer call is already at the type checker's limit.
        if let existing {
            track_.acoustidFingerprint = existing.acoustidFingerprint
            track_.acoustidID = existing.acoustidID
            track_.skipAfterSeconds = existing.skipAfterSeconds
            track_.replaygainTrackGain = tags.replayGain.trackGain ?? existing.replaygainTrackGain
            track_.replaygainTrackPeak = tags.replayGain.trackPeak ?? existing.replaygainTrackPeak
            track_.replaygainAlbumGain = tags.replayGain.albumGain ?? existing.replaygainAlbumGain
            track_.replaygainAlbumPeak = tags.replayGain.albumPeak ?? existing.replaygainAlbumPeak
        }
        if audioUnchanged, let existing {
            track_.carryProvenance(from: existing)
            // The sync content hash (ETag) is valid exactly as long as the
            // bytes are; a changed file must re-hash (#423).
            track_.contentHash = existing.contentHash
        }

        let id = try await trackRepo.upsert(track_)
        track_.id = id

        // Roll tag-supplied totals up to the album row once this track's
        // values are persisted; skipped when the album already agrees, which
        // is every track after the first on a rescan (#404).
        if let albumID = album.id,
           tags.trackTotal != nil || tags.discTotal != nil,
           album.totalTracks != tags.trackTotal || album.totalDiscs != tags.discTotal {
            try await self.albumRepo.recomputeTotals(albumID: albumID)
        }
        // Same for the MusicBrainz release / release-group IDs (#402). An album
        // built from mixed pressings keeps a NULL release ID by design, so
        // each of its tagged tracks re-runs the (cheap) rollup on rescan.
        if let albumID = album.id,
           tags.musicbrainzReleaseID != nil || tags.musicbrainzReleaseGroupID != nil,
           album.musicbrainzReleaseID != tags.musicbrainzReleaseID
           || album.musicbrainzReleaseGroupID != tags.musicbrainzReleaseGroupID {
            try await self.albumRepo.recomputeMusicBrainzIDs(albumID: albumID)
        }

        // Persist lyrics if present
        if let lyricsText = tags.lyrics, !lyricsText.isEmpty {
            let doc = LRCParser.parseDocument(lyricsText)
            let lyricsRecord = Lyrics(
                trackID: id,
                lyricsText: lyricsText,
                isSynced: { if case .synced = doc { return true }
                    return false
                }(),
                source: "embedded"
            )
            try await lyricsRepo.save(lyricsRecord)
        }

        self.log.debug("track.import", ["url": url.lastPathComponent, "id": id])
        return id
    }

    // MARK: - Helpers

    /// Ingests a sidecar cover image from the track's folder through the
    /// hash-addressed cache, so dedup and eviction apply exactly as for
    /// embedded art (#388). Never throws: a broken sidecar must not sink the
    /// track import, so failures log and return nil.
    private func persistSidecarArt(besideTrackAt url: URL) async -> (hash: String, path: String)? {
        let directory = url.deletingLastPathComponent()
        guard let artURL = SidecarArt.findURL(inDirectory: directory) else { return nil }
        do {
            let data = try Data(contentsOf: artURL)
            let art = ExtractedCoverArt(
                data: data,
                mimeType: SidecarArt.mimeType(forExtension: artURL.pathExtension),
                pictureType: 3 // front cover
            )
            let persisted = try await self.coverArtCache.persist([art], source: "sidecar")
            if persisted != nil {
                self.log.debug("cover_art.sidecar", ["file": artURL.lastPathComponent])
            }
            return persisted
        } catch {
            self.log.warning("cover_art.sidecar_failed", [
                "file": artURL.lastPathComponent,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    private func isLossless(format: String) -> Bool {
        ["flac", "wav", "aiff", "aif", "alac", "wv", "ape", "dsf", "dff"].contains(format)
    }

    /// Encodes the multi-valued tag dictionary as a deterministic JSON string.
    /// Keys are sorted so the column stays diff-stable across rescans of the
    /// same file. Returns `nil` for an empty map (column stays NULL).
    private func encodeExtendedTags(_ map: [String: [String]]) -> String? {
        guard !map.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(map)
            return String(data: data, encoding: .utf8)
        } catch {
            self.log.warning("track.extended_tags.encode_failed", [
                "error": String(reflecting: error),
            ])
            return nil
        }
    }
}
