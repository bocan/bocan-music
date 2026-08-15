import Foundation
import Library
import Testing
@testable import UI

@Suite("RuleBuilderView validation")
struct RuleBuilderViewValidationTests {
    @Test("invalid regex disables save")
    @MainActor
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

    @Test("IntField never applies locale grouping separators")
    func intFieldNeverGroups() throws {
        // Source-convention guard: the rule builder's integer fields hold
        // exact values (year, play count), where a plain `.number` format
        // renders 1980 as "1,980". The field cannot be exercised host-less,
        // so pin the format style in source.
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Playlists/Smart/RuleRowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("format: .number.grouping(.never)"))
        #expect(!source.contains("format: .number)"))
    }
}
