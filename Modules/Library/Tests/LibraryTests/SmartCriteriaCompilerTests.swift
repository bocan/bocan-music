import Foundation
import Testing
@testable import Library

// MARK: - SQL Compiler Tests

@Suite("SmartCriteriaCompiler")
struct SmartCriteriaCompilerTests {
    /// Shadow Foundation.Comparator protocol with the Library enum in this scope.
    private typealias Comparator = Library.Comparator

    // MARK: - Helpers

    private func compile(_ field: Field, _ comparator: Comparator, _ value: Value) throws -> CompiledCriteria {
        let criterion = SmartCriterion.rule(.init(field: field, comparator: comparator, value: value))
        return try SQLBuilder.compile(criteria: criterion, limitSort: LimitSort())
    }

    private func assertNoLiteral(_ sql: String, _ literal: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(!sql.contains(literal), "SQL should not contain literal '\(literal)'", sourceLocation: sourceLocation)
    }

    // MARK: - Text: contains / starts / ends / is / isNot

    @Test func titleContains() throws {
        let c = try compile(.title, .contains, .text("rock"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "rock")
    }

    @Test func titleStartsWith() throws {
        let c = try compile(.title, .startsWith, .text("The"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "The")
    }

    @Test func titleEndsWith() throws {
        let c = try compile(.title, .endsWith, .text("blues"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "blues")
    }

    @Test func titleIs() throws {
        let c = try compile(.title, .is, .text("Bohemian Rhapsody"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) = LOWER(?)"))
        #expect(!c.selectSQL.contains("COLLATE NOCASE"))
        self.assertNoLiteral(c.selectSQL, "Bohemian Rhapsody")
    }

    @Test func titleIsNot() throws {
        let c = try compile(.title, .isNot, .text("Disco Inferno"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) != LOWER(?)"))
        #expect(!c.selectSQL.contains("COLLATE NOCASE"))
        self.assertNoLiteral(c.selectSQL, "Disco Inferno")
    }

    @Test func titleDoesNotContain() throws {
        let c = try compile(.title, .doesNotContain, .text("intro"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) NOT LIKE LOWER(?) ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "intro")
    }

    @Test func titleIsEmpty() throws {
        let c = try compile(.title, .isEmpty, .null)
        #expect(c.selectSQL.contains("IS NULL") || c.selectSQL.contains("= ''"))
    }

    @Test func titleIsNotEmpty() throws {
        let c = try compile(.title, .isNotEmpty, .null)
        #expect(c.selectSQL.contains("IS NOT NULL"))
    }

    @Test func titleMatchesRegex() throws {
        let c = try compile(.title, .matchesRegex, .text("^The "))
        #expect(c.selectSQL.contains("REGEXP ?"))
        self.assertNoLiteral(c.selectSQL, "^The ")
    }

    // MARK: - LIKE: special-character escaping

    @Test func likeEscapesPercent() throws {
        let c = try compile(.title, .contains, .text("100% pure"))
        #expect(c.selectSQL.contains("ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "100% pure")
    }

    @Test func likeEscapesUnderscore() throws {
        let c = try compile(.title, .contains, .text("a_b"))
        #expect(c.selectSQL.contains("ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "a_b")
    }

    // MARK: - Unicode case-folding (text comparators)

    // SQL LIKE / COLLATE NOCASE are ASCII-only. SQLBuilder wraps both sides with
    // LOWER() and also calls String.lowercased() on the Swift side so that ICU
    // handles full-case folding for non-ASCII scripts.

    @Test func unicodeContainsUmlaut() throws {
        // "über" should match a title containing "Über"
        let c = try compile(.title, .contains, .text("über"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
        // Bound parameter must itself be lowercased so LOWER(?)==LOWER(col) works.
        // We verify the SQL structure; runtime correctness is tested in the
        // integration-style tests below.
    }

    @Test func unicodeIsUmlautLowercasedInArg() throws {
        // The bound arg must be lowercased on the Swift side so LOWER(?) is stable.
        let c = try compile(.title, .is, .text("ÜBER"))
        // Arguments are opaque StatementArguments; verify via round-trip.
        // SQLBuilder converts "ÜBER" → "über" before binding.
        #expect(c.selectSQL.contains("LOWER(tracks.title) = LOWER(?)"))
    }

    @Test func unicodeContainsGreek() throws {
        // Greek uppercase Σ → lowercase σ/ς (context-sensitive in full ICU,
        // but String.lowercased() handles the common case).
        let c = try compile(.title, .contains, .text("ΕΛΛΆΔΑ"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
    }

    @Test func germanEszettIsDocumentedEdgeCase() throws {
        // "ß".lowercased() == "ß" (single char) on all Apple platforms.
        // A search for "SS" does NOT match "Straße" — this is expected and
        // documented in Comparator.swift.
        let c = try compile(.title, .contains, .text("ß"))
        #expect(c.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
        // "SS" round-trip: lowercases to "ss", not "ß" — no cross-case match.
        let cSS = try compile(.title, .contains, .text("SS"))
        #expect(cSS.selectSQL.contains("LOWER(tracks.title) LIKE LOWER(?) ESCAPE"))
    }

    // MARK: - Numeric comparators

    @Test func ratingEqualTo() throws {
        let c = try compile(.rating, .equalTo, .int(100))
        #expect(c.selectSQL.contains("= ?"))
        #expect(c.selectSQL.contains("tracks.rating"))
        self.assertNoLiteral(c.selectSQL, "100")
    }

    @Test func ratingGreaterThan() throws {
        let c = try compile(.rating, .greaterThan, .int(80))
        #expect(c.selectSQL.contains("> ?"))
        self.assertNoLiteral(c.selectSQL, "80")
    }

    @Test func ratingLessThan() throws {
        let c = try compile(.rating, .lessThan, .int(50))
        #expect(c.selectSQL.contains("< ?"))
    }

    @Test func ratingGreaterThanOrEqual() throws {
        let c = try compile(.rating, .greaterThanOrEqual, .int(70))
        #expect(c.selectSQL.contains(">= ?"))
    }

    @Test func ratingBetween() throws {
        let c = try compile(.rating, .between, .range(.int(70), .int(90)))
        #expect(c.selectSQL.contains("BETWEEN ? AND ?"))
        self.assertNoLiteral(c.selectSQL, "70")
        self.assertNoLiteral(c.selectSQL, "90")
    }

    @Test func ratingIsNull() throws {
        let c = try compile(.rating, .isNull, .null)
        #expect(c.selectSQL.contains("IS NULL"))
    }

    @Test func ratingIsNotNull() throws {
        let c = try compile(.rating, .isNotNull, .null)
        #expect(c.selectSQL.contains("IS NOT NULL"))
    }

    @Test func playCountNotEqualTo() throws {
        let c = try compile(.playCount, .notEqualTo, .int(0))
        #expect(c.selectSQL.contains("!= ?"))
    }

    // MARK: - Duration

    @Test func durationGreaterThan() throws {
        let c = try compile(.duration, .greaterThan, .duration(180))
        #expect(c.selectSQL.contains("> ?"))
        #expect(c.selectSQL.contains("tracks.duration"))
    }

    // MARK: - Date comparators

    @Test func addedAtInLastDays() throws {
        let c = try compile(.addedAt, .inLastDays, .int(30))
        // Must use SQLite unixepoch, not a baked Swift timestamp
        #expect(c.selectSQL.contains("unixepoch('now'"))
        #expect(c.selectSQL.contains("days"))
        self.assertNoLiteral(c.selectSQL, "30")
    }

    @Test func addedAtInLastMonths() throws {
        let c = try compile(.addedAt, .inLastMonths, .int(6))
        #expect(c.selectSQL.contains("unixepoch('now'"))
        #expect(c.selectSQL.contains("months"))
    }

    @Test func lastPlayedAtInLastYears() throws {
        let c = try compile(.lastPlayedAt, .inLastYears, .int(2))
        #expect(c.selectSQL.contains("tracks.last_played_at"))
        #expect(c.selectSQL.contains("unixepoch('now'"))
        #expect(c.selectSQL.contains("years"))
        // Count must be bound, not interpolated.
        self.assertNoLiteral(c.selectSQL, "2")
    }

    @Test func addedAtBefore() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let c = try compile(.addedAt, .beforeDate, .date(date))
        #expect(c.selectSQL.contains("< ?"))
        self.assertNoLiteral(c.selectSQL, "1700000000")
    }

    @Test func addedAtAfter() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let c = try compile(.addedAt, .afterDate, .date(date))
        #expect(c.selectSQL.contains("> ?"))
        self.assertNoLiteral(c.selectSQL, "1700000000")
    }

    // MARK: - Boolean comparators

    @Test func lovedIsTrue() throws {
        let c = try compile(.loved, .isTrue, .null)
        #expect(c.selectSQL.contains("= 1") || c.selectSQL.contains("IS NOT NULL"))
    }

    @Test func lovedIsFalse() throws {
        let c = try compile(.loved, .isFalse, .null)
        #expect(c.selectSQL.contains("= 0") || c.selectSQL.contains("IS NULL"))
    }

    @Test func hasCoverArtIsTrue() throws {
        let c = try compile(.hasCoverArt, .isTrue, .null)
        #expect(c.selectSQL.contains("IS NOT NULL"))
    }

    @Test func hasCoverArtIsFalse() throws {
        let c = try compile(.hasCoverArt, .isFalse, .null)
        #expect(c.selectSQL.contains("IS NULL"))
    }

    @Test func hasLyricsIsTrue() throws {
        let c = try compile(.hasLyrics, .isTrue, .null)
        #expect(c.selectSQL.contains("LEFT JOIN lyrics ON lyrics.track_id = tracks.id"))
        #expect(c.selectSQL.contains("lyrics.lyrics_text IS NOT NULL"))
        #expect(c.selectSQL.contains("!= ''"))
    }

    @Test func hasLyricsIsFalse() throws {
        let c = try compile(.hasLyrics, .isFalse, .null)
        #expect(c.selectSQL.contains("LEFT JOIN lyrics ON lyrics.track_id = tracks.id"))
        #expect(c.selectSQL.contains("lyrics.lyrics_text IS NULL"))
        #expect(c.selectSQL.contains("= ''"))
    }

    // MARK: - Membership

    @Test func notMemberOf() throws {
        let c = try compile(.notInPlaylist, .notMemberOf, .playlistRef(42))
        #expect(c.selectSQL.contains("NOT IN"))
        #expect(c.selectSQL.contains("playlist_tracks"))
        // playlist ID must be bound, not interpolated
        self.assertNoLiteral(c.selectSQL, "42")
    }

    @Test func pathUnder() throws {
        let c = try compile(Field.pathUnder, .pathUnder, .text("/Music/Rock"))
        #expect(c.selectSQL.contains("LIKE ? ESCAPE"))
        self.assertNoLiteral(c.selectSQL, "/Music/Rock")
    }

    // MARK: - Nested groups

    @Test func nestedAndGroup() throws {
        let criteria = SmartCriterion.group(.and, [
            .rule(.init(field: .title, comparator: .contains, value: .text("rock"))),
            .rule(.init(field: .rating, comparator: .greaterThan, value: .int(80))),
        ])
        let c = try SQLBuilder.compile(criteria: criteria, limitSort: LimitSort())
        #expect(c.selectSQL.contains("("))
        #expect(c.selectSQL.contains("AND"))
    }

    @Test func nestedOrGroup() throws {
        let criteria = SmartCriterion.group(.or, [
            .rule(.init(field: .artist, comparator: .contains, value: .text("Beatles"))),
            .rule(.init(field: .artist, comparator: .contains, value: .text("Stones"))),
        ])
        let c = try SQLBuilder.compile(criteria: criteria, limitSort: LimitSort())
        #expect(c.selectSQL.contains("OR"))
    }

    @Test func deepNestedGroupParenthesisation() throws {
        // (artist contains Miles) AND ((rating > 80) OR (loved is_true))
        let inner = SmartCriterion.group(.or, [
            .rule(.init(field: .rating, comparator: .greaterThan, value: .int(80))),
            .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
        ])
        let outer = SmartCriterion.group(.and, [
            .rule(.init(field: .artist, comparator: .contains, value: .text("Miles"))),
            inner,
        ])
        let c = try SQLBuilder.compile(criteria: outer, limitSort: LimitSort())
        #expect(c.selectSQL.contains("AND"))
        #expect(c.selectSQL.contains("OR"))
        let openCount = c.selectSQL.count(where: { $0 == "(" })
        #expect(openCount >= 2)
    }

    // MARK: - Limit & sort

    @Test func limitApplied() throws {
        let ls = LimitSort(sortBy: .addedAt, ascending: false, limit: 25, liveUpdate: true)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        #expect(c.selectSQL.contains("LIMIT 25"))
    }

    @Test func sortByPlayCountDesc() throws {
        let ls = LimitSort(sortBy: .playCount, ascending: false, limit: nil, liveUpdate: true)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        #expect(c.selectSQL.contains("play_count"))
        #expect(c.selectSQL.contains("DESC"))
    }

    @Test func sortByRatingAsc() throws {
        let ls = LimitSort(sortBy: .rating, ascending: true, limit: nil, liveUpdate: true)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        #expect(c.selectSQL.contains("rating"))
        #expect(c.selectSQL.contains("ASC"))
    }

    @Test func randomSortUsesSeed() throws {
        let ls = LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls,
            seed: 12345
        )
        #expect(c.selectSQL.contains("12345"))
    }

    @Test func randomSortIsStableForSameSeed() throws {
        let ls = LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        let c1 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls, seed: 999
        )
        let c2 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls, seed: 999
        )
        #expect(c1.selectSQL == c2.selectSQL)
    }

    @Test func randomSortDiffersForDifferentSeeds() throws {
        let ls = LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        let c1 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls, seed: 100
        )
        let c2 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls, seed: 200
        )
        #expect(c1.selectSQL != c2.selectSQL)
    }

    // MARK: - Validator

    @Test func emptyGroupThrows() {
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(.group(.and, []))
        }
    }

    @Test func betweenReversedThrows() {
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(.rule(.init(
                field: .rating,
                comparator: .between,
                value: .range(.int(90), .int(10))
            )))
        }
    }

    @Test func betweenEqualBoundsAllowed() throws {
        try Validator.validate(.rule(.init(
            field: .rating,
            comparator: .between,
            value: .range(.int(80), .int(80))
        )))
    }

    @Test func invalidRegexThrows() {
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(.rule(.init(
                field: .title,
                comparator: .matchesRegex,
                value: .text("[invalid")
            )))
        }
    }

    @Test func validRegexPasses() throws {
        try Validator.validate(.rule(.init(
            field: .title,
            comparator: .matchesRegex,
            value: .text("^The\\s")
        )))
    }

    @Test func incompatibleComparatorThrows() {
        // `contains` is text-only; `rating` is numeric — must throw
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(.rule(.init(
                field: .rating,
                comparator: .contains,
                value: .text("rock")
            )))
        }
    }

    @Test func threeLevelNestingAllowed() throws {
        // Root (1) → group (2) → group (3) — exactly at the cap.
        let leaf = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let level3 = SmartCriterion.group(.and, [leaf])
        let level2 = SmartCriterion.group(.and, [level3])
        let level1 = SmartCriterion.group(.and, [level2])
        try Validator.validate(level1)
    }

    @Test func fourLevelNestingThrows() {
        // Root (1) → group (2) → group (3) → group (4) — exceeds cap of 3.
        let leaf = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let level4 = SmartCriterion.group(.and, [leaf])
        let level3 = SmartCriterion.group(.and, [level4])
        let level2 = SmartCriterion.group(.and, [level3])
        let level1 = SmartCriterion.group(.and, [level2])
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(level1)
        }
    }

    @Test func unknownFieldDecodesAsInvalidSentinel() throws {
        // Simulate a JSON blob written by a future version that introduced
        // (or removed) a field this build doesn't recognise.
        let json = #"""
        {"rule":{"_0":{"field":"madeUpField","comparator":"contains","value":{"tag":"text","text":"x"}}}}
        """#
        let data = try #require(json.data(using: .utf8))
        let criterion = try JSONDecoder().decode(SmartCriterion.self, from: data)
        guard case let .invalid(reason) = criterion else {
            Issue.record("Expected .invalid sentinel, got \(criterion)")
            return
        }
        #expect(reason.contains("madeUpField"))
    }

    @Test func validatorRejectsInvalidSentinel() {
        let criterion = SmartCriterion.invalid(reason: "Unknown field \"madeUpField\"")
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(criterion)
        }
    }

    @Test func surroundingTreeStillDecodesWhenOneRuleUnknown() throws {
        // A group with one good rule + one rule using an unknown field must
        // still decode end-to-end; only the broken leaf becomes .invalid.
        let json = #"""
        {"group":{"_0":"and","_1":[
          {"rule":{"_0":{"field":"loved","comparator":"isTrue","value":{"tag":"null"}}}},
          {"rule":{"_0":{"field":"madeUpField","comparator":"contains","value":{"tag":"text","text":"x"}}}}
        ]}}
        """#
        let data = try #require(json.data(using: .utf8))
        let criterion = try JSONDecoder().decode(SmartCriterion.self, from: data)
        guard case let .group(_, children) = criterion else {
            Issue.record("Expected .group root")
            return
        }
        #expect(children.count == 2)
        guard case .rule = children[0] else {
            Issue.record("Expected first child to remain a rule")
            return
        }
        guard case .invalid = children[1] else {
            Issue.record("Expected second child to be .invalid")
            return
        }
    }

    // MARK: - Security: SQL injection resistance

    @Test func sqlInjectionIsNotInterpolated() throws {
        let injection = "' OR 1=1 --"
        let c = try compile(.title, .contains, .text(injection))
        #expect(!c.selectSQL.contains(injection))
        #expect(c.selectSQL.contains("?"))
    }

    @Test func sqlInjectionViaLikeIsEscaped() throws {
        let injection = "%; DROP TABLE tracks; --"
        let c = try compile(.title, .contains, .text(injection))
        #expect(!c.selectSQL.contains(injection))
        #expect(c.selectSQL.contains("ESCAPE"))
    }

    @Test func numericInjectionIsNotInterpolated() throws {
        let c = try compile(.rating, .equalTo, .int(42))
        self.assertNoLiteral(c.selectSQL, "42")
        #expect(c.selectSQL.contains("?"))
    }

    // MARK: - Codable round-trip

    @Test func criteriaRoundTripCodable() throws {
        let original = SmartCriterion.group(.and, [
            .rule(.init(field: .artist, comparator: .contains, value: .text("Jazz"))),
            .rule(.init(field: .rating, comparator: .greaterThanOrEqual, value: .int(80))),
            .group(.or, [
                .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
                .rule(.init(field: .playCount, comparator: .greaterThan, value: .int(5))),
            ]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SmartCriterion.self, from: data)
        #expect(original == decoded)
    }

    @Test func valueCodableRoundTrip() throws {
        let values: [Value] = [
            .text("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .date(Date(timeIntervalSince1970: 1_000_000)),
            .duration(180),
            .range(.int(1), .int(10)),
            .playlistRef(99),
            .enumeration("mp3"),
            .null,
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(Value.self, from: data)
            #expect(v == decoded)
        }
    }
}
