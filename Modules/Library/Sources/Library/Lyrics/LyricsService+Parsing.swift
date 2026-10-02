import Foundation
import Metadata
import Persistence

// MARK: - Pure helpers

extension LyricsService {
    func parse(row: Lyrics) -> LyricsDocument? {
        guard let text = row.lyricsText, !text.isEmpty else { return nil }
        var doc = LRCParser.parseDocument(text)
        // Apply the stored per-track display offset on top of any in-file [offset:] tag.
        if row.offsetMS != 0 {
            switch doc {
            case let .synced(lines, existingOffset):
                doc = .synced(lines: lines, offsetMS: existingOffset + row.offsetMS)

            case .unsynced:
                break
            }
        }
        return doc
    }

    /// `tracks.file_url` holds a URL *string* ("file:///…"); passing it to
    /// `URL(fileURLWithPath:)` mangles it into a relative garbage path, the bug
    /// that silently broke sidecar loading and no-bookmark embeds since ADR-015.
    /// Plain absolute paths (legacy rows, tests) are still accepted.
    static func fileURL(from string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL {
            return url
        }
        if string.hasPrefix("/") {
            return URL(fileURLWithPath: string)
        }
        return nil
    }
}
