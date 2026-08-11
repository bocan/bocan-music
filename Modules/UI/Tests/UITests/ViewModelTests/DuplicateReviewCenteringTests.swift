import Foundation
import Testing
@testable import UI

// MARK: - DuplicateReviewCenteringTests

/// Regression (user-reported): the Duplicate Review sheet's empty states
/// ("No Duplicates Found", "Could Not Load") sat left-aligned because the
/// enclosing VStack is `.leading` (for the list rows) and the
/// `ContentUnavailableView`s did not fill the width. Both must carry
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)` to centre, matching
/// the loading state. Source-convention test: the sheet cannot be
/// exercised host-less.
@Suite("Duplicate Review empty-state centering")
struct DuplicateReviewCenteringTests {
    private func sheetSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Tools/DuplicateReviewSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("both empty states fill the width so they centre")
    func emptyStatesFillWidth() throws {
        let source = try self.sheetSource()
        // The loading state plus the two ContentUnavailableView cases each
        // need the fill-width frame; guard against a regression to two.
        let fills = source.components(
            separatedBy: ".frame(maxWidth: .infinity, maxHeight: .infinity)"
        ).count - 1
        #expect(fills >= 3, "loading and both empty states must fill the width to centre")
    }
}
