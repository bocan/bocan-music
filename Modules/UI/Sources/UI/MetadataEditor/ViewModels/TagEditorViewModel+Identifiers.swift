import Foundation

// MARK: - Read-only identifier display

/// Read-only display values surfaced in the Tag Editor's "Identifiers"
/// section. These rows show MusicBrainz IDs that exist on the underlying
/// track / album rows but aren't editable through this view — they come
/// from file tags or the database scanner, not user edits.
public extension TagEditorViewModel {
    /// MusicBrainz recording ID for the loaded track(s). Empty when no
    /// track has one; `"Various"` when values differ or some have a
    /// value and others don't; otherwise the shared value.
    var recordingMBIDDisplay: String {
        Self.identifierDisplay(self.loadedTracksByID.values.map(\.musicbrainzRecordingID))
    }

    /// MusicBrainz release ID (the album's MBID, denormalised onto each
    /// track row at scan time). Single-album selections collapse to the
    /// shared release MBID; cross-album selections produce `"Various"`.
    var releaseMBIDDisplay: String {
        Self.identifierDisplay(self.loadedTracksByID.values.map(\.musicbrainzReleaseID))
    }

    /// Reduce a per-track identifier column to a single display string.
    /// Treats empty strings as missing so a tag that's present but blank
    /// doesn't trigger `"Various"` against rows where the column is nil.
    private static func identifierDisplay(_ raw: [String?]) -> String {
        let normalised: [String?] = raw.map { ($0?.isEmpty == true) ? nil : $0 }
        guard let first = normalised.first else { return "" }
        let allSame = normalised.dropFirst().allSatisfy { $0 == first }
        if !allSame { return "Various" }
        return first ?? ""
    }
}
