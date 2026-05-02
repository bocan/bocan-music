import Foundation

// MARK: - LyricsMode helpers

/// LRC timestamp detection and effective lyrics-mode resolution.
extension TagEditorViewModel {
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
