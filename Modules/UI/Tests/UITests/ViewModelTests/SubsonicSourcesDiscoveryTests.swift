import Foundation
import Testing
@testable import UI

// MARK: - SubsonicSourcesDiscoveryTests

/// Guards that an empty Sources sidebar section offers a tappable way to add a
/// server (#309). A first-time user must be able to find server setup without
/// discovering the header "+" or a context-menu action. The affordance is a
/// SwiftUI view detail, so this pins the source contract.
@Suite("Subsonic sources discovery")
struct SubsonicSourcesDiscoveryTests {
    private func source() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/AppRoot/SubsonicSidebarSection.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Empty Sources section shows a tappable 'Add a Server' button (#309)")
    func emptyStateIsTappable() throws {
        let src = try self.source()
        #expect(src.contains("Add a Server"), "The empty Sources state must offer an 'Add a Server' affordance")
        #expect(
            src.contains("A11y.SourcesSidebar.emptyStateAddButton"),
            "The empty-state CTA must be an identifiable control"
        )
    }

    @Test("Empty-state CTA invokes the add-source handler that opens Settings (#309)")
    func ctaInvokesAddSource() throws {
        let src = try self.source()
        // The button must call onAddSource (which routes to Settings -> Sources),
        // not just render inert text.
        #expect(
            src.contains("Button { onAddSource() }"),
            "The empty-state CTA must call onAddSource"
        )
    }
}
