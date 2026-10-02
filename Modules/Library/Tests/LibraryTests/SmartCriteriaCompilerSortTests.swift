import Foundation
import Testing
@testable import Library

// MARK: - SQL Compiler Tests: groups, limit and sort

@Suite("SmartCriteriaCompiler groups and sort")
struct SmartCriteriaCompilerSortTests {
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
        let openCount = c.selectSQL.count { $0 == "(" }
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
            limitSort: ls,
            seed: 999
        )
        let c2 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls,
            seed: 999
        )
        #expect(c1.selectSQL == c2.selectSQL)
    }

    @Test func randomSortDiffersForDifferentSeeds() throws {
        let ls = LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        let c1 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls,
            seed: 100
        )
        let c2 = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls,
            seed: 200
        )
        #expect(c1.selectSQL != c2.selectSQL)
    }

    // MARK: - Multi-key sort

    @Test func multiKeySortEmitsOrderedTerms() throws {
        let ls = LimitSort(sortDescriptors: [
            SmartSortDescriptor(key: .artist, ascending: true),
            SmartSortDescriptor(key: .trackNumber, ascending: true),
            SmartSortDescriptor(key: .title, ascending: true),
        ])
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        let order = try #require(c.selectSQL.range(of: "ORDER BY"))
        let orderClause = String(c.selectSQL[order.lowerBound...])
        #expect(orderClause.contains("artists.name ASC, tracks.track_number ASC, tracks.title ASC"))
    }

    @Test func sortByArtistWithoutRuleStillJoinsArtists() throws {
        // Sorting by artist when no rule references the artist table must add
        // the join, or the query references an unjoined `artists.name`.
        let ls = LimitSort(sortBy: .artist, ascending: true)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        #expect(c.selectSQL.contains("JOIN artists"))
        #expect(c.selectSQL.contains("artists.name ASC"))
    }

    @Test func sortByAlbumWithoutRuleStillJoinsAlbums() throws {
        let ls = LimitSort(sortBy: .album, ascending: false)
        let c = try SQLBuilder.compile(
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
            limitSort: ls
        )
        #expect(c.selectSQL.contains("JOIN albums"))
        #expect(c.selectSQL.contains("albums.title DESC"))
    }
}
