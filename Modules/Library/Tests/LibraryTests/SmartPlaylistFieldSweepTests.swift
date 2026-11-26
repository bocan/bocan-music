import Foundation
import Testing
@testable import Library
@testable import Persistence

/// Runs one rule per field against a real, fully migrated database, with the
/// value shape the rule editor stores. The compiler tests only read the SQL
/// text, so a rule that names a missing column (Comment, #727) or a value the
/// compiler refuses (File Format) passed them and failed for the user.
@Suite("Smart playlist field sweep")
struct SmartPlaylistFieldSweepTests: SmartPlaylistServiceFixtures {
    /// Every field the rule editor offers runs without an error.
    @Test(arguments: Field.allCases.filter { Self.editorRule(for: $0) != nil })
    func everyFieldRunsAgainstTheSchema(field: Field) async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        _ = try await insertTrack(in: db, fileURL: "file:///probe.flac")
        let rule = try #require(Self.editorRule(for: field))

        let playlist = try await svc.create(name: "Probe", criteria: .rule(rule))
        let pid = try #require(playlist.id)
        _ = try await svc.tracks(for: pid)
    }

    /// Only the playlist-membership comparators are left out of the sweep:
    /// they need a playlist to point at, build their own SQL, and have their
    /// own tests in `SmartPlaylistServiceTests`.
    @Test func sweepLeavesOutOnlyPlaylistMembership() {
        let skipped = Set(Field.allCases.filter { Self.editorRule(for: $0) == nil })
        #expect(skipped == [.inPlaylist, .notInPlaylist])
    }

    /// "File Format is FLAC" as the editor saves it, with the picked option
    /// stored as an enumeration value, not as text.
    @Test func fileFormatRuleMatchesThePickedFormat() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let flac = try await insertTrack(in: db, fileURL: "file:///a.flac", fileFormat: "flac")
        let mp3 = try await insertTrack(in: db, fileURL: "file:///b.mp3", fileFormat: "mp3")

        let isFLAC = try await svc.create(
            name: "FLAC",
            criteria: .rule(.init(field: .fileFormat, comparator: .is, value: .enumeration("flac")))
        )
        let notFLAC = try await svc.create(
            name: "Not FLAC",
            criteria: .rule(.init(field: .fileFormat, comparator: .isNot, value: .enumeration("flac")))
        )
        #expect(try await svc.tracks(for: #require(isFLAC.id)).compactMap(\.id) == [flac])
        #expect(try await svc.tracks(for: #require(notFLAC.id)).compactMap(\.id) == [mp3])
    }

    /// The rule the editor builds for `field`: the first comparator it offers
    /// and the value the editor seeds for that comparator and data type.
    private static func editorRule(for field: Field) -> SmartCriterion.Rule? {
        let def = FieldDefinitions.definition(for: field)
        guard let comparator = def.allowedComparators.first else { return nil }
        let value: Value
        switch (comparator, def.dataType) {
        case (.memberOf, _), (.notMemberOf, _):
            return nil

        case (.pathUnder, _):
            value = .text("/")

        case (.isTrue, _), (.isFalse, _):
            value = .null

        case (.between, _):
            value = .range(.int(0), .int(100))

        case (.inLastDays, _), (.notInLastDays, _):
            value = .int(30)

        case (_, .text):
            value = .text("a")

        case (_, .numeric):
            value = .int(1)

        case (_, .date):
            value = .date(Date())

        case (_, .duration):
            value = .duration(60)

        case let (_, .enumeration(options)):
            value = .enumeration(options.first ?? "")

        case (_, .bool), (_, .membership):
            value = .null
        }
        return .init(field: field, comparator: comparator, value: value)
    }
}
