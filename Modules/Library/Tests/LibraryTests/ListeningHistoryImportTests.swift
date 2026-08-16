import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - LastFMExportParserTests

/// The parser against the real export shape (ADR-076 slice 1): quoted fields,
/// commas inside the redundant utc_time column, blank MBIDs, and junk rows.
@Suite("LastFMExportParser")
struct LastFMExportParserTests {
    /// Verbatim shape of the official export, quoted commas and all.
    private static let sample = """
    uts,utc_time,artist,artist_mbid,album,album_mbid,track,track_mbid
    "1784613695","21 Jul 2026, 06:01","William Michael Morgan","1d782734-6d89-4166-b8a5-a4c581e48d3b","RED","","RED",""
    "1784560028","20 Jul 2026, 15:07","Jason Scott & The High Heat","e8a873f4-9009-4e66-80dd-d618530627dc","How To Get Away With Murder","","How To Get Away With Murder",""
    "1784540348","20 Jul 2026, 09:39","Cole Gibbs","","Don't Lie","c6b4a219-deb8-4f82-86e7-3400fc5e20dc","Don't Lie","11111111-2222-3333-4444-555555555555"
    """

    @Test("The official export header and rows parse cleanly")
    func officialShapeParses() throws {
        let result = try LastFMExportParser.parse(Self.sample)
        #expect(result.malformedRows == 0)
        #expect(result.listens.count == 3)
        let first = try #require(result.listens.first)
        #expect(first.playedAt == 1_784_613_695)
        #expect(first.artist == "William Michael Morgan")
        #expect(first.title == "RED")
        #expect(first.album == "RED")
        #expect(first.trackMbid == nil, "a blank track_mbid must become nil, not an empty string")
        #expect(result.listens[1].artist == "Jason Scott & The High Heat")
        #expect(result.listens[2].trackMbid == "11111111-2222-3333-4444-555555555555")
    }

    @Test("Embedded commas, escaped quotes, and CRLF endings survive")
    func csvEdgeCases() throws {
        let tricky = "uts,artist,track,album\r\n" +
            "\"100\",\"Songs, The Band\",\"A \"\"Quoted\"\" Song\",\"Album, With Comma\"\r\n"
        let result = try LastFMExportParser.parse(tricky)
        #expect(result.malformedRows == 0)
        let listen = try #require(result.listens.first)
        #expect(listen.artist == "Songs, The Band")
        #expect(listen.title == "A \"Quoted\" Song")
        #expect(listen.album == "Album, With Comma")
    }

    @Test("Broken rows are counted and skipped, never fatal")
    func malformedRowsSkipped() throws {
        let mixed = """
        uts,utc_time,artist,artist_mbid,album,album_mbid,track,track_mbid
        "not-a-number","x","Artist","","Album","","Track",""
        "2000","x","","","Album","","Track",""
        "3000","x","Artist","","Album","","Track",""
        """
        let result = try LastFMExportParser.parse(mixed)
        #expect(result.malformedRows == 2)
        #expect(result.listens.count == 1)
        #expect(result.listens.first?.playedAt == 3000)
    }

    @Test("A CSV that is not a Last.fm export is rejected with a clear error")
    func wrongCSVRejected() {
        #expect(throws: LibraryError.self) {
            _ = try LastFMExportParser.parse("name,age\nchris,44\n")
        }
        #expect(throws: LibraryError.self) {
            _ = try LastFMExportParser.parse("")
        }
    }
}

// MARK: - ListeningHistoryImporterTests

/// End-to-end import (ADR-076 slice 1): file to stored, matched rows.
@Suite("ListeningHistoryImporter")
struct ListeningHistoryImporterTests {
    @Test("An export file lands stored, matched, and idempotent")
    func endToEndImport() async throws {
        let db = try await Database(location: .inMemory)
        // A local track the export should match, case-insensitively.
        _ = try await db.write { grdb -> Int64 in
            var artist = Artist(name: "William Michael Morgan")
            try artist.insert(grdb)
            var track = Track(
                fileURL: "file:///tmp/red.flac",
                fileFormat: "flac",
                duration: 200,
                title: "Red",
                addedAt: 0,
                updatedAt: 0
            )
            track.artistID = artist.id
            try track.insert(grdb)
            return try #require(track.id)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lastfm-\(UUID().uuidString).csv")
        let csv = """
        uts,utc_time,artist,artist_mbid,album,album_mbid,track,track_mbid
        "1784613695","21 Jul 2026, 06:01","William Michael Morgan","","RED","","RED",""
        "1784568383","20 Jul 2026, 17:26","Myles Morgan","","Road Sign","","Road Sign",""
        """
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let importer = ListeningHistoryImporter(database: db)
        let summary = try await importer.importExport(at: url)
        #expect(summary.parsed == 2)
        #expect(summary.inserted == 2)
        #expect(summary.malformedRows == 0)
        #expect(summary.newlyMatched == 1, "RED matches the local track; Road Sign has nothing to match")
        #expect(summary.totalStored == 2)
        #expect(summary.totalMatched == 1)

        // Importing the same file again adds nothing.
        let again = try await importer.importExport(at: url)
        #expect(again.inserted == 0)
        #expect(again.duplicates == 2)
        #expect(again.totalStored == 2)

        try FileManager.default.removeItem(at: url)
    }
}
