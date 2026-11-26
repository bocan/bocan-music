import Foundation
import Metadata
import Persistence

// MARK: - Tag map upkeep (#735)

/// `tracks.extended_tags` describes the file, not the user's edit: no edited
/// column depends on it, and the Comment smart playlist field reads only it.
/// So the scan keeps it in step with the file for user-edited rows too.
extension ScanCoordinator {
    /// Sets `track`'s tag map from `tags`, the tags just read from its file.
    /// A failed encode keeps the old map and logs.
    func refreshTagMap(on track: inout Track, from tags: TrackTags) {
        do {
            track.extendedTags = try ExtendedTagsJSON.encode(tags.extendedTags)
        } catch {
            self.log.warning("scan.tagMap.encodeFailed", [
                "file": URL(string: track.fileURL)?.lastPathComponent ?? track.fileURL,
                "error": String(reflecting: error),
            ])
        }
    }

    /// One-time fill for an unchanged file whose row has never stored its tag
    /// map: a row imported before M015, or one edited in Get Info before the
    /// editor wrote the map. The quick scan otherwise never opens an unchanged
    /// file, so without this the map stays NULL for good.
    ///
    /// Reads the tags and writes only `extended_tags`. It does not compare
    /// tags or raise a conflict: the file has not changed since the row last
    /// saw it. Every failure is logged and the file stays skipped; the next
    /// quick scan tries again.
    func backfillTagMap(url: URL) async {
        let tags: TrackTags
        do {
            tags = try self.tagReader.read(from: url)
        } catch {
            self.log.warning("scan.tagMap.readFailed", [
                "file": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
            return
        }
        do {
            guard let id = try await self.trackRepo.fetchOne(fileURL: url.absoluteString)?.id else { return }
            try await self.trackRepo.setExtendedTags(trackID: id, json: ExtendedTagsJSON.encode(tags.extendedTags))
        } catch {
            self.log.warning("scan.tagMap.writeFailed", [
                "file": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
        }
    }
}
