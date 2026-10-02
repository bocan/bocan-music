import Foundation
import Testing
@testable import Library

// MARK: - SQL Compiler Tests: validator, injection resistance, Codable

@Suite("SmartCriteria validation, injection resistance and coding")
struct SmartCriteriaValidationTests: SmartCriteriaCompilerFixtures {
    /// Shadow Foundation.Comparator protocol with the Library enum in this scope.
    private typealias Comparator = Library.Comparator

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
        // `contains` is text-only; `rating` is numeric, so it must throw
        #expect(throws: SmartPlaylistError.self) {
            try Validator.validate(.rule(.init(
                field: .rating,
                comparator: .contains,
                value: .text("rock")
            )))
        }
    }

    @Test func threeLevelNestingAllowed() throws {
        // Root (1) → group (2) → group (3): exactly at the cap.
        let leaf = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let level3 = SmartCriterion.group(.and, [leaf])
        let level2 = SmartCriterion.group(.and, [level3])
        let level1 = SmartCriterion.group(.and, [level2])
        try Validator.validate(level1)
    }

    @Test func fourLevelNestingThrows() {
        // Root (1) → group (2) → group (3) → group (4): exceeds cap of 3.
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
        #expect(reason.contains("newer version"))
    }

    @Test func unknownComparatorDecodesAsInvalidSentinel() throws {
        let json = #"""
        {"rule":{"_0":{"field":"title","comparator":"brandNewComparator","value":{"tag":"text","text":"x"}}}}
        """#
        let data = try #require(json.data(using: .utf8))
        let criterion = try JSONDecoder().decode(SmartCriterion.self, from: data)
        guard case let .invalid(reason) = criterion else {
            Issue.record("Expected .invalid sentinel, got \(criterion)")
            return
        }
        #expect(reason.contains("newer version"))
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
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(Value.self, from: data)
            #expect(value == decoded)
        }
    }

    @Test func fieldUnknownRoundTripPreservesRawString() throws {
        let original = Field.unknown("futureField")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Field.self, from: data)
        guard case let .unknown(raw) = decoded else {
            Issue.record("Expected .unknown field, got \(decoded)")
            return
        }
        #expect(raw == "futureField")

        guard let encoded = String(data: data, encoding: .utf8) else {
            Issue.record("Encoded field data was not UTF-8")
            return
        }
        #expect(encoded == #""futureField""#)
    }

    @Test func comparatorUnknownRoundTripPreservesRawString() throws {
        let original = Comparator.unknown("futureComparator")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Comparator.self, from: data)
        guard case let .unknown(raw) = decoded else {
            Issue.record("Expected .unknown comparator, got \(decoded)")
            return
        }
        #expect(raw == "futureComparator")

        guard let encoded = String(data: data, encoding: .utf8) else {
            Issue.record("Encoded comparator data was not UTF-8")
            return
        }
        #expect(encoded == #""futureComparator""#)
    }
}
