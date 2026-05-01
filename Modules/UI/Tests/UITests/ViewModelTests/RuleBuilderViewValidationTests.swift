import Foundation
import Library
import Testing
@testable import UI

@Suite("RuleBuilderView validation")
struct RuleBuilderViewValidationTests {
    @Test("invalid regex disables save")
    func invalidRegexDisablesSave() {
        let root = EditableCriterion.group(
            id: UUID(),
            op: .and,
            children: [
                .rule(
                    id: UUID(),
                    EditableRule(
                        field: .title,
                        comparator: .matchesRegex,
                        value: .text("[invalid")
                    )
                ),
            ]
        )

        let result = RuleBuilderView.validationResult(for: root)
        #expect(result.error != nil)
        #expect(!result.nodeErrors.isEmpty)
        #expect(RuleBuilderView.isSaveDisabled(isSaving: false, validationError: result.error))
    }
}
