import Library
import Metadata
import Observability
import Persistence

// MARK: - TagEditorViewModel + Conflict Resolution

/// Conflict-resolution actions and diff-row computation for `TagEditorViewModel`.
public extension TagEditorViewModel {
    // MARK: - Actions

    /// Acknowledges the disk change for all conflicting tracks without applying it.
    /// Clears the `needs_conflict_review` flag; user edits are preserved.
    func keepMyEdits() async {
        let ids = self.conflictTrackIDs
        for trackID in ids {
            do {
                try await self.service.clearConflictFlag(trackID: trackID)
            } catch {
                self.log.error("conflict.keep_failed", ["trackID": trackID, "error": String(reflecting: error)])
            }
        }
        self.conflictTrackIDs = []
        self.log.debug("conflict.kept_edits", ["count": ids.count])
    }

    /// Accepts the on-disk version for all conflicting tracks.
    /// Clears `user_edited` and `needs_conflict_review`; reloads fields from disk.
    func takeDiskVersion() async {
        let ids = self.conflictTrackIDs
        for trackID in ids {
            do {
                try await self.service.acceptDiskVersion(trackID: trackID)
            } catch {
                self.log.error("conflict.take_disk_failed", ["trackID": trackID, "error": String(reflecting: error)])
            }
        }
        self.conflictTrackIDs = []
        self.log.debug("conflict.took_disk", ["count": ids.count])
        // Reload the sheet so fields reflect what is now on disk.
        await self.load()
    }

    // MARK: - Diff rows

    /// Rows for the side-by-side diff sheet.
    /// Compares DB-stored values (user's last edit) with the tags now on disk.
    /// Artist / album name resolution requires an extra DB join and is omitted here.
    var conflictDiffRows: [ConflictDiffRow] {
        guard let trackID = self.trackIDs.first,
              let diskTags = self.loadedTagsByID[trackID],
              let dbTrack = self.loadedTracksByID[trackID] else { return [] }

        var rows: [ConflictDiffRow] = []
        func add(_ label: String, stored: String?, disk: String?) {
            let storedVal = stored ?? ""
            let diskVal = disk ?? ""
            if storedVal != diskVal {
                rows.append(ConflictDiffRow(label: label, stored: storedVal, disk: diskVal))
            }
        }

        add("Title", stored: dbTrack.title, disk: diskTags.title)
        add("Genre", stored: dbTrack.genre, disk: diskTags.genre)
        add("Composer", stored: dbTrack.composer, disk: diskTags.composer)
        add("ISRC", stored: dbTrack.isrc, disk: diskTags.isrc)
        add("Key", stored: dbTrack.key, disk: diskTags.key)
        add("Year", stored: dbTrack.year.map(String.init), disk: diskTags.year.map(String.init))
        add("Track #", stored: dbTrack.trackNumber.map(String.init), disk: diskTags.trackNumber.map(String.init))
        add("Track Total", stored: dbTrack.trackTotal.map(String.init), disk: diskTags.trackTotal.map(String.init))
        add("Disc #", stored: dbTrack.discNumber.map(String.init), disk: diskTags.discNumber.map(String.init))
        add("Disc Total", stored: dbTrack.discTotal.map(String.init), disk: diskTags.discTotal.map(String.init))
        add(
            "BPM",
            stored: dbTrack.bpm.map { String(format: "%.0f", $0) },
            disk: diskTags.bpm.map { String(format: "%.0f", $0) }
        )
        return rows
    }
}
