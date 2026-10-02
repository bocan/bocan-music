import Foundation
import Observability
import Persistence

// MARK: - Saving a guessed match to tags

/// Writes a guessed MusicBrainz match into the file tags, on the user's request.
public extension DeepDiveService {
    /// Writes a guessed track match into the file's tags through the metadata
    /// editor (backups, undo, DB row update included), then returns the
    /// report unflagged and re-caches it. The next scan reads the id back
    /// from the file like any tagged id.
    func confirmTrackMatch(report: TrackReport, saver: any DeepDiveTagSaving) async throws -> TrackReport {
        try await saver.saveRecordingID(report.recordingMBID, trackID: report.trackID)
        self.log.info("deepdive.track.savedToTags", ["trackID": report.trackID, "mbid": report.recordingMBID])
        var confirmed = report
        confirmed.mbidGuessed = false
        await self.cache.store(confirmed, key: "recording-\(report.recordingMBID)")
        return confirmed
    }

    /// Writes a guessed album match (its release-group id) into the tags of
    /// every track of the album in one edit transaction. Returns the
    /// unflagged report and the number of files written.
    func confirmAlbumMatch(
        report: AlbumReport,
        saver: any DeepDiveTagSaving
    ) async throws -> (report: AlbumReport, tracksWritten: Int) {
        guard let groupID = report.releaseGroupMBID else { throw DeepDiveError.noIdentifier }
        let ids = try await self.tracks.fetchAll(albumID: report.albumID).compactMap(\.id)
        guard !ids.isEmpty else { throw DeepDiveError.notFound }
        try await saver.saveReleaseGroupID(groupID, trackIDs: ids)
        self.log.info("deepdive.album.savedToTags", ["albumID": report.albumID, "mbid": groupID, "tracks": ids.count])
        var confirmed = report
        confirmed.mbidGuessed = false
        await self.cache.store(confirmed, key: "album-\(report.albumID)")
        return (confirmed, ids.count)
    }
}
