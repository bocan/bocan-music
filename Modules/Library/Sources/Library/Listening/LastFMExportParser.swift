import Foundation
import Persistence

/// Parses the official Last.fm listening-history export (phase 25-1).
///
/// The shape: one header row naming the columns (`uts`, `utc_time`, `artist`,
/// `artist_mbid`, `album`, `album_mbid`, `track`, `track_mbid`), then one
/// quoted CSV row per scrobble. Only `uts`, `artist`, and `track` are
/// required; `utc_time` is redundant with `uts` (UTC epoch seconds) and is
/// ignored, which also sidesteps its locale-formatted, comma-bearing dates.
/// Fields may be quoted, with embedded commas and doubled-quote escapes.
public enum LastFMExportParser {
    /// Parsed listens plus the honest count of rows that could not be read.
    public struct ParseResult: Equatable, Sendable {
        public let listens: [ImportedListen]
        public let malformedRows: Int
    }

    /// Parses the full text of an export file.
    ///
    /// - Throws: `LibraryError.listenExportUnreadable` when the header is
    ///   missing the required columns (the file is some other CSV entirely).
    ///   Individually broken rows are skipped and counted, never fatal.
    public static func parse(_ text: String) throws -> ParseResult {
        let rows = Self.csvRows(text)
        guard let header = rows.first else {
            throw LibraryError.listenExportUnreadable(reason: "empty file")
        }
        var columns: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if columns[key] == nil {
                columns[key] = index
            }
        }
        guard
            let utsIndex = columns["uts"],
            let artistIndex = columns["artist"],
            let trackIndex = columns["track"] else {
            throw LibraryError.listenExportUnreadable(reason: "header lacks uts/artist/track columns")
        }

        var listens: [ImportedListen] = []
        listens.reserveCapacity(rows.count - 1)
        var malformed = 0
        for row in rows.dropFirst() {
            guard
                row.count > max(utsIndex, artistIndex, trackIndex),
                let uts = Int64(row[utsIndex].trimmingCharacters(in: .whitespaces)),
                uts > 0 else {
                malformed += 1
                continue
            }
            let artist = row[artistIndex].trimmingCharacters(in: .whitespaces)
            let title = row[trackIndex].trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty, !title.isEmpty else {
                malformed += 1
                continue
            }
            listens.append(ImportedListen(
                playedAt: uts,
                artist: artist,
                title: title,
                album: self.optionalField(row, at: columns["album"]),
                trackMbid: self.optionalField(row, at: columns["track_mbid"])
            ))
        }
        return ParseResult(listens: listens, malformedRows: malformed)
    }

    // MARK: - CSV

    private static func optionalField(_ row: [String], at index: Int?) -> String? {
        guard let index, row.indices.contains(index) else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Minimal RFC 4180 tokenizer: quoted fields, doubled-quote escapes,
    /// LF / CRLF / CR row endings. Blank lines are skipped.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inQuotes {
                if char == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true

                case ",":
                    row.append(field)
                    field = ""

                // "\r\n" is a single Character in Swift (one grapheme
                // cluster), so CRLF needs its own case or it lands in the
                // default branch and corrupts the field.
                case "\n", "\r", "\r\n":
                    if !row.isEmpty || !field.isEmpty {
                        row.append(field)
                        rows.append(row)
                        row = []
                        field = ""
                    }

                default:
                    field.append(char)
                }
            }
            index = text.index(after: index)
        }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
