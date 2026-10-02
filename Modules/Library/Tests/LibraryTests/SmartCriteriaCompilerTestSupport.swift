import Foundation
import Testing
@testable import Library

/// Helpers shared by the smart-criteria compiler suites. A suite conforms to
/// get them as `compile(...)` and `self.assertNoLiteral(...)`.
protocol SmartCriteriaCompilerFixtures {}

extension SmartCriteriaCompilerFixtures {
    func compile(_ field: Field, _ comparator: Library.Comparator, _ value: Value) throws -> CompiledCriteria {
        let criterion = SmartCriterion.rule(.init(field: field, comparator: comparator, value: value))
        return try SQLBuilder.compile(criteria: criterion, limitSort: LimitSort())
    }

    func assertNoLiteral(_ sql: String, _ literal: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(!sql.contains(literal), "SQL should not contain literal '\(literal)'", sourceLocation: sourceLocation)
    }
}
