import Foundation
import Observability
import TagLibBridge

// MARK: - TagWriter

/// Writes tag metadata back to audio files via the TagLib Obj-C++ bridge.
///
/// Writes are **atomic at the file level**: the original is copied to a sibling
/// temp file, tags are written to the copy, `fsync(2)` is called, then
/// `rename(2)` replaces the original.  On any failure the original is untouched.
/// The copy goes to the system temporary directory only when no sibling can be
/// created, because a temp file on another volume turns that rename into a
/// cross-volume replacement that macOS refuses at folder level (#511).
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

        // 1. Copy original → temp (preserves audio payload)
        let tmpURL = try self.stageCopy(of: url, fileManager: fm)

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
                throw MetadataError.writeFailed(url, Self.replaceFailureReason(url: url, error: error, fileManager: fm))
            }
        } catch {
            do {
                try fm.removeItem(at: tmpURL)
            } catch let cleanupError {
                self.log.warning("taglib.tmp.cleanup.failed", ["error": String(reflecting: cleanupError)])
            }
            throw error
        }

        self.log.debug("taglib.write", ["path": url.lastPathComponent])
    }

    // MARK: - Staging

    /// Copies `url` to the file the new tags are written into, and returns it.
    ///
    /// A sibling of the original keeps the later replacement on the same
    /// volume, where it is a rename. Staging in the system temporary directory
    /// makes that replacement cross-volume for every library that is not on the
    /// boot volume, and macOS then fails it at folder level even though the
    /// file itself is perfectly writable (#511).
    ///
    /// The system temporary directory stays as the fallback: for a file added
    /// through "Add Files…" the sandbox grants the bookmark on the file and not
    /// on its parent folder, so no sibling can be created there. The copy
    /// itself decides which one is used, rather than a permission check that
    /// the sandbox can answer differently from the write.
    func stageCopy(of url: URL, fileManager fm: FileManager = .default) throws -> URL {
        let sibling = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        do {
            try fm.copyItem(at: url, to: sibling)
            return sibling
        } catch {
            self.log.debug("taglib.tmp.sibling_unavailable", [
                "file": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
        }
        // A failed copy can still leave a partial sibling behind.
        try? fm.removeItem(at: sibling)

        let fallback = fm.temporaryDirectory
            .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        do {
            try fm.copyItem(at: url, to: fallback)
            return fallback
        } catch {
            throw MetadataError.writeFailed(url, "Copy to temp failed: \(error.localizedDescription)")
        }
    }

    /// Cocoa reports a failed replacement at folder level ("couldn't be saved
    /// in the folder …"), which reads as though the file were at fault. Name
    /// the folder when the folder is the obstacle (#511).
    ///
    /// The early guard cannot make this check: a file added through "Add
    /// Files…" has a writable file inside a folder the process cannot write,
    /// and that write still succeeds.
    private static func replaceFailureReason(url: URL, error: Error, fileManager fm: FileManager) -> String {
        let folder = url.deletingLastPathComponent()
        guard !fm.isWritableFile(atPath: folder.path(percentEncoded: false)) else {
            return "Replace failed: \(error.localizedDescription)"
        }
        return "Replace failed: the folder \(folder.lastPathComponent) is not writable "
            + "(\(error.localizedDescription))"
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
        boc.releaseType = tags.releaseType
        boc.musicbrainzTrackID = tags.musicbrainzTrackID
        boc.musicbrainzRecordingID = tags.musicbrainzRecordingID
        boc.musicbrainzArtistID = tags.musicbrainzArtistID
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
