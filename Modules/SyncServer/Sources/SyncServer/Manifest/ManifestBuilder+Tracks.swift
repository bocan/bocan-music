import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - Tracks

extension ManifestBuilder {
    /// What a track row is resolved against: the library roots for `relPath`,
    /// and the artist and album names by id.
    struct TrackLookups {
        let roots: [LibraryRoot]
        let artistName: [Int64: String]
        let albumTitle: [Int64: String]
    }

    /// The file-describing fields of a manifest entry: the source file's, or
    /// the prepared artifact's under a transcode preset (ADR-088).
    struct TrackFile {
        let relPath: String
        let size: Int64
        let sha256: String
        let format: String
    }

    /// A prepared artifact: its ledger row and the preset it was encoded with.
    struct PreparedArtifact {
        let row: SyncTranscode
        let preset: TranscodePreset
    }

    func buildTracks(
        allTracks: [Track],
        profileTrackIds: Set<Int64>,
        lookups: TrackLookups,
        preset: TranscodePreset?,
        ledger: [Int64: SyncTranscode]
    ) -> [ManifestTrack] {
        let candidates = allTracks
            .filter { !$0.disabled }
            .filter { $0.id.map { profileTrackIds.contains($0) } ?? false }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }

        var result: [ManifestTrack] = []
        var skipped = 0
        var awaiting = 0

        for track in candidates {
            guard let id = track.id else { continue }
            guard let hash = track.contentHash else { skipped += 1
                continue
            }
            guard let relPath = Self.relPath(for: track.fileURL, roots: lookups.roots) else { skipped += 1
                continue
            }
            if let preset, TranscodeCoordinator.needsTranscode(track, preset: preset) {
                // ADR-088 served-bytes rule: describe the artifact, and only
                // once it is prepared (the same gate shape as a missing hash);
                // the sync grows as the coordinator's pass progresses.
                guard let row = ledger[id] else { awaiting += 1
                    continue
                }
                result.append(self.makeArtifactTrack(
                    track,
                    id: id,
                    relPath: relPath,
                    artifact: PreparedArtifact(row: row, preset: preset),
                    lookups: lookups
                ))
                continue
            }
            result.append(self.makeTrack(
                track,
                id: id,
                file: TrackFile(relPath: relPath, size: track.fileSize, sha256: hash, format: track.fileFormat),
                clip: nil,
                lookups: lookups
            ))
        }

        if skipped > 0 {
            self.log.debug("manifest.tracks.skipped", ["count": skipped])
        }
        if awaiting > 0 {
            self.log.debug("manifest.tracks.awaiting_transcode", ["count": awaiting])
        }
        return result.sorted { $0.id < $1.id }
    }

    /// A manifest entry whose file-describing fields are the prepared
    /// artifact's (ADR-088): ledger size and hash, the preset's format and
    /// extension, lossy artifact properties, and `sourceFormat` for display.
    private func makeArtifactTrack(
        _ track: Track,
        id: Int64,
        relPath: String,
        artifact prepared: PreparedArtifact,
        lookups: TrackLookups
    ) -> ManifestTrack {
        let row = prepared.row
        let preset = prepared.preset
        var artifact = self.makeTrack(
            track,
            id: id,
            file: TrackFile(
                relPath: Self.swapExtension(relPath, to: preset.fileExtension),
                size: row.size,
                sha256: row.sha256,
                format: preset.formatName
            ),
            clip: nil,
            lookups: lookups
        )
        artifact.sourceFormat = track.fileFormat
        artifact.bitrate = row.bitrate ?? preset.targetKbps
        artifact.sampleRate = Int(preset.outputSampleRate(forSourceRate: Int32(track.sampleRate ?? 44100)))
        artifact.bitDepth = nil
        artifact.channelCount = track.channelCount.map { min($0, 2) }
        artifact.isLossless = false
        return artifact
    }

    /// The artifact's relPath: the source path with the preset's extension,
    /// so the bytes and the filename agree on the phone.
    static func swapExtension(_ relPath: String, to ext: String) -> String {
        (relPath as NSString).deletingPathExtension + "." + ext
    }

    private func makeTrack(
        _ track: Track,
        id: Int64,
        file: TrackFile,
        clip: ManifestClip?,
        lookups: TrackLookups
    ) -> ManifestTrack {
        ManifestTrack(
            id: id,
            relPath: file.relPath,
            size: file.size,
            sha256: file.sha256,
            format: file.format,
            durationMs: Int((track.duration * 1000).rounded()),
            title: track.title,
            artist: track.artistID.flatMap { lookups.artistName[$0] },
            artistId: track.artistID,
            albumArtist: track.albumArtistID.flatMap { lookups.artistName[$0] },
            albumArtistId: track.albumArtistID,
            album: track.albumID.flatMap { lookups.albumTitle[$0] },
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
            sourceFormat: nil,
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
}
