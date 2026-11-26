import Foundation
import Testing
@testable import Library
@testable import Persistence

/// Runs Comment rules against a real, fully migrated database. The compiler
/// tests only look at the SQL text, which is how a rule on a column that
/// does not exist shipped (#727). The every-field sweep is in
/// `SmartPlaylistFieldSweepTests`.
@Suite("Smart playlist Comment rules")
struct SmartPlaylistFieldQueryTests: SmartPlaylistServiceFixtures {
    @Test func commentRulesReadTheCommentTag() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let bbc = try await insertTrack(
            in: db,
            fileURL: "file:///bbc.mp3",
            extendedTags: #"{"ARTIST":["Bootleg Beatles"],"COMMENT":["Live at the BBC"]}"#
        )
        let twoValues = try await insertTrack(
            in: db,
            fileURL: "file:///two.flac",
            extendedTags: #"{"COMMENT":["Remaster","Bootleg"]}"#
        )
        let blank = try await insertTrack(in: db, fileURL: "file:///blank.mp3", extendedTags: #"{"COMMENT":["   "]}"#)
        let none = try await insertTrack(in: db, fileURL: "file:///none.mp3")
        let otherKeyOnly = try await insertTrack(
            in: db,
            fileURL: "file:///itunes.mp3",
            extendedTags: #"{"COMMENT:ITUNES_CDDB_1":["bootleg"]}"#
        )

        // Case-insensitive, and every COMMENT value is searched; other tags
        // and description-keyed comment frames are not.
        #expect(try await self.ids(svc, .contains, .text("bootleg")) == [twoValues])
        #expect(try await self.ids(svc, .contains, .text("bbc")) == [bbc])
        #expect(try await self.ids(svc, .isEmpty, .null) == [blank, none, otherKeyOnly])
        #expect(try await self.ids(svc, .isNotEmpty, .null) == [bbc, twoValues])
        #expect(try await self.ids(svc, .doesNotContain, .text("bbc")) == [twoValues, blank, none, otherKeyOnly])
    }

    @Test func commentRuleSurvivesARowWithBadJSON() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let good = try await insertTrack(in: db, fileURL: "file:///good.mp3", extendedTags: #"{"COMMENT":["keep"]}"#)
        _ = try await insertTrack(in: db, fileURL: "file:///bad.mp3", extendedTags: "{not json")

        #expect(try await self.ids(svc, .contains, .text("keep")) == [good])
    }

    private func ids(
        _ svc: SmartPlaylistService,
        _ comparator: Library.Comparator,
        _ value: Value
    ) async throws -> Set<Int64> {
        let playlist = try await svc.create(
            name: "Comment \(comparator.rawValue)",
            criteria: .rule(.init(field: .comment, comparator: comparator, value: value))
        )
        let pid = try #require(playlist.id)
        return try await Set(svc.tracks(for: pid).compactMap(\.id))
    }
}
