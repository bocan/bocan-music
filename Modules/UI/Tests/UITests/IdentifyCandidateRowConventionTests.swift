import Foundation
import Testing
@testable import UI

// MARK: - IdentifyCandidateRowConventionTests

/// Source-convention checks for the identify-track candidate picker's interaction
/// fixes. Hit-testing, hover, and keyboard behaviour cannot be exercised host-less,
/// so these assert the structural wiring: the whole row header hit-tests (not just
/// the opaque text), rows carry a disclosure affordance, and Return applies.
@Suite("Identify candidate row source conventions")
struct IdentifyCandidateRowConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func pickerSource() throws -> String {
        try self.source("Sources/UI/Fingerprint/CandidatePickerView.swift")
    }

    @Test("Row header applies contentShape inside the plain Button's label")
    func contentShapeInsideButtonLabel() throws {
        let source = try self.pickerSource()
        // A plain Button only hit-tests its opaque label content; the Rectangle
        // contentShape must sit inside the label chain (before .buttonStyle(.plain))
        // or the Spacer gap between title and badge is a dead zone.
        let shape = try #require(source.range(of: ".contentShape(Rectangle())"))
        let style = try #require(source.range(of: ".buttonStyle(.plain)"))
        #expect(shape.lowerBound < style.lowerBound)
    }

    @Test("Rows show a disclosure chevron that rotates when expanded")
    func disclosureChevron() throws {
        let source = try self.pickerSource()
        #expect(source.contains("chevron.right"))
        #expect(source.contains("rotationEffect"))
    }

    @Test("Rows highlight on hover")
    func hoverHighlight() throws {
        let source = try self.pickerSource()
        #expect(source.contains(".onHover"))
    }

    @Test("Return triggers Apply Selected")
    func returnAppliesSelection() throws {
        let source = try self.pickerSource()
        #expect(source.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test("Field checkboxes speak current and proposed values")
    func checkboxSpeaksDiff() throws {
        let source = try self.pickerSource()
        #expect(source.contains("Accept \\(field.displayName), currently \\(currentSpoken), proposed \\(proposed)"))
    }
}
