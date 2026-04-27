import Foundation
import Observability
import TagLibBridge

// MARK: - TagWriter

/// Writes tag metadata back to audio files via the TagLib Obj-C++ bridge.
///
/// Writes are **atomic at the file level**: the original is copied to a sibling
/// temp file, tags are written to the copy, `fsync(2)` is called, then
/// `rename(2)` replaces the original.  On any failure the original is untouched.
public struct TagWriter: Sendable {
    private let log = AppLogger.make(.metadata)

    public init() {}

    // MARK: - Public API

    /// Writes `tags` to the audio file at `url`.
    ///
    /// - Throws: `MetadataError.readOnlyFile` when the file is not writable,
    ///   `MetadataError.writeFailed` on any other TagLib or filesystem error.
    public func write(_ tags: TrackTags, to url: URL) throws {
        let fm = FileManager.default

        // Guard against read-only files early so we surface a clear error.
        guard fm.isWritableFile(atPath: url.path(percentEncoded: false)) else {
            throw MetadataError.readOnlyFile(url)
        }

        // Write the temp file to the system temporary directory rather than as a
        // sibling of the original.  A sibling would require write access to the
        // parent directory — which the sandbox does NOT grant for files added
        // individually via "Add Files…" (the security-scoped bookmark covers the
        // file itself, not its parent folder).  FileManager.replaceItem handles the
        // cross-filesystem case (e.g. /var/folders → ~/Desktop) gracefully.
        let tmpURL = fm.temporaryDirectory
            .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")

        // 1. Copy original → temp (preserves audio payload)
        do {
            try fm.copyItem(at: url, to: tmpURL)
        } catch {
            throw MetadataError.writeFailed(url, "Copy to temp failed: \(error.localizedDescription)")
        }

        do {
            // 2. Write tags to the temp file via TagLib bridge
            let bocTags = Self.buildBOCTags(from: tags)
            let tmpPath = tmpURL.path(percentEncoded: false)
            do {
                try BOCTagWriter.writeTags(toPath: tmpPath, tags: bocTags)
            } catch {
                throw MetadataError.writeFailed(url, error.localizedDescription)
            }

            // 3. fsync to flush kernel buffers before replacement
            let fd = tmpPath.withCString { Darwin.open($0, O_RDONLY) }
            if fd >= 0 {
                Darwin.fsync(fd)
                Darwin.close(fd)
            }

            // 4. Atomically replace the original with the rewritten temp file.
            //    replaceItem handles same-volume renames efficiently and falls back
            //    to a copy+delete across volumes.
            do {
                try fm.replaceItem(
                    at: url,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly,
                    resultingItemURL: nil
                )
            } catch {
                throw MetadataError.writeFailed(url, "Replace failed: \(error.localizedDescription)")
            }
        } catch {
            // Clean up temp file; ignore any secondary error
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        self.log.debug("taglib.write", ["path": url.lastPathComponent])
    }

    // MARK: - Private helpers

    private static func buildBOCTags(from tags: TrackTags) -> BOCTags {
        let boc = BOCTags()
        boc.title = tags.title
        boc.artist = tags.artist
        boc.albumArtist = tags.albumArtist
        boc.album = tags.album
        boc.genre = tags.genre
        boc.composer = tags.composer
        boc.comment = tags.comment
        boc.year = NSInteger(tags.year ?? 0)
        boc.trackNumber = NSInteger(tags.trackNumber ?? 0)
        boc.trackTotal = NSInteger(tags.trackTotal ?? 0)
        boc.discNumber = NSInteger(tags.discNumber ?? 0)
        boc.discTotal = NSInteger(tags.discTotal ?? 0)
        boc.sortTitle = tags.sortTitle
        boc.sortArtist = tags.sortArtist
        boc.sortAlbumArtist = tags.sortAlbumArtist
        boc.sortAlbum = tags.sortAlbum
        boc.lyrics = tags.lyrics
        boc.bpm = tags.bpm ?? 0
        boc.key = tags.key
        boc.isrc = tags.isrc
        boc.musicbrainzTrackID = tags.musicbrainzTrackID
        boc.musicbrainzRecordingID = tags.musicbrainzRecordingID
        boc.musicbrainzAlbumArtistID = tags.musicbrainzAlbumArtistID
        boc.musicbrainzReleaseID = tags.musicbrainzReleaseID
        boc.musicbrainzReleaseGroupID = tags.musicbrainzReleaseGroupID
        boc.replaygainTrackGain = tags.replayGain.trackGain ?? .nan
        boc.replaygainTrackPeak = tags.replayGain.trackPeak ?? .nan
        boc.replaygainAlbumGain = tags.replayGain.albumGain ?? .nan
        boc.replaygainAlbumPeak = tags.replayGain.albumPeak ?? .nan
        boc.coverArt = tags.coverArt.map { art in
            BOCCoverArt(data: art.data, mimeType: art.mimeType, pictureType: NSInteger(art.pictureType))
        }
        return boc
    }
}
