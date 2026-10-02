import Foundation
import Testing
@testable import Library

/// A field this build does not know (criteria written by a newer app) decodes
/// as `Field.unknown`. It is not in the definition table, so the lookup used
/// to crash the UI that renders the rule. It must degrade and be rejected.
@Suite("SmartCriteria unknown field")
struct SmartCriteriaUnknownFieldTests {
    private typealias Comparator = Library.Comparator

    @Test("the definition lookup returns a field that no comparator can use")
    func definitionLookupDoesNotCrash() {
        let definition = FieldDefinitions.definition(for: .unknown("futureField"))
        #expect(definition.allowedComparators.isEmpty)
        #expect(definition.columnRef.expression == "NULL")
    }

    @Test("every known field has its own definition")
    func knownFieldsAreInTheTable() {
        for field in Field.allCases {
            #expect(
                FieldDefinitions.definition(for: field).columnRef.expression != "NULL",
                "\(field) fell back to the unknown definition"
            )
        }
    }

    @Test("compiling a rule on an unknown field throws")
    func compileRejectsUnknownField() {
        let criterion = SmartCriterion.rule(.init(
            field: .unknown("futureField"),
            comparator: .contains,
            value: .text("x")
        ))
        #expect(throws: SmartPlaylistError.self) {
            try SQLBuilder.compile(criteria: criterion, limitSort: LimitSort())
        }
    }
}
