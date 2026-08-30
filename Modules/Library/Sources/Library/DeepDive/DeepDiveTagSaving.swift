import Foundation

// MARK: - DeepDiveTagSaving

/// Writes a confirmed Deep Dive name match into file tags. Implemented by
/// `MetadataEditService`, so the write goes through the same transaction as
/// any tag edit: backup ring, `user_edited`, DB row update, undo. The seam
/// exists so `DeepDiveService` tests can inject a recorder instead of
/// touching real files.
public protocol DeepDiveTagSaving: Sendable {
    /// Writes the recording MBID into one track's file.
    func saveRecordingID(_ mbid: String, trackID: Int64) async throws
    /// Writes the release-group MBID into every listed track's file.
    func saveReleaseGroupID(_ mbid: String, trackIDs: [Int64]) async throws
}

extension MetadataEditService: DeepDiveTagSaving {
    public func saveRecordingID(_ mbid: String, trackID: Int64) async throws {
        var patch = TrackTagPatch()
        patch.musicbrainzRecordingID = .some(mbid)
        try await self.edit(trackID: trackID, patch: patch)
    }

    public func saveReleaseGroupID(_ mbid: String, trackIDs: [Int64]) async throws {
        var patch = TrackTagPatch()
        patch.musicbrainzReleaseGroupID = .some(mbid)
        try await self.edit(trackIDs: trackIDs, patch: patch)
    }
}
