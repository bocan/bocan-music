import Foundation
import Metadata

// MARK: - LyricsMode helpers

/// LRC timestamp detection, effective lyrics-mode resolution, and the
/// stored-lyrics merge for the Get Info lyrics tab.
extension TagEditorViewModel {
    // MARK: - Stored-lyrics merge

    /// Merges lyrics stored in the DB table over the file-tag values.
    ///
    /// Lyrics fetched from LRClib or edited in the lyrics panel live in the
    /// lyrics DB table and are deliberately NOT written into the file unless
    /// the user opted in to embedding — so the file tag alone leaves the Get
    /// Info tab empty while the lyrics pane clearly shows lyrics. The stored
    /// row wins; it is what the app resolves everywhere else.
    func mergeStoredLyrics(_ stored: [Int64: String], tagsByID: [Int64: TrackTags]) {
        self.lyrics = Self.fieldState(Self.effectiveLyrics(
            trackIDs: self.trackIDs,
            tagsByID: tagsByID,
            stored: stored
        ))
    }

    /// Per-track effective lyrics: the stored DB row when one exists, else the
    /// file-tag value. Order and membership mirror `populate(from:)` — only
    /// tracks whose tags actually loaded contribute a slot.
    static func effectiveLyrics(
        trackIDs: [Int64],
        tagsByID: [Int64: TrackTags],
        stored: [Int64: String]
    ) -> [String?] {
        trackIDs.compactMap { id -> String?? in
            guard let tags = tagsByID[id] else { return nil } // read failed — no slot
            return .some(stored[id] ?? tags.lyrics)
        }
    }

    // MARK: - LRC detection

    /// `true` when the current lyrics text contains LRC timestamp patterns (`[mm:ss` …).
    ///
    /// Used by the auto-detect mode to decide whether to save as synced lyrics.
    var lrcTimestampsDetected: Bool {
        let text: String?
        switch self.lyrics {
        case let .shared(val):
            text = val

        case let .edited(val):
            text = val

        case .various:
            return false
        }
        guard let t = text, !t.isEmpty else { return false }
        return Self.containsLRCTimestamps(t)
    }

    /// `true` when `lyricsMode` is `.synced`, or `.auto` and timestamps are detected.
    var effectiveLyricsIsSynced: Bool {
        switch self.lyricsMode {
        case .synced:
            true

        case .plain:
            false

        case .auto:
            self.lrcTimestampsDetected
        }
    }

    static func containsLRCTimestamps(_ text: String) -> Bool {
        // Match any line beginning with [mm:ss or [mm:ss.xx]
        let pattern = #"^\[\d{1,2}:\d{2}"#
        return text.components(separatedBy: "\n").contains { line in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
