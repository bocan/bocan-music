import Foundation
import Testing

// MARK: - PodcastsGridScrollRestoreConventionTests

/// Source-convention checks for `PodcastsGridView` scroll-restore behaviour that
/// can't be exercised host-less: returning from a show restores the grid offset
/// instead of snapping back to the top (mirrors the album-grid scroll restore,
/// #349).
@Suite("Podcasts grid scroll restore conventions")
struct PodcastsGridScrollRestoreConventionTests {
    private func gridSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/Podcasts/PodcastsGridView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The grid saves and restores its scroll offset across show visits (#349)")
    func gridRestoresScrollOffset() throws {
        let source = try self.gridSource()
        // Capture the live offset, snapshot it into the view model when opening a
        // show, and restore via ScrollPosition when the grid reappears.
        #expect(
            source.contains(".onScrollGeometryChange(for: CGFloat.self)"),
            "the grid must observe scroll geometry to capture the live offset"
        )
        #expect(
            source.contains("self.vm.gridScrollOffset = Double(self.liveScrollOffset)"),
            "opening a show must snapshot the offset into the view model"
        )
        #expect(
            source.contains("self.scrollPosition.scrollTo(y: CGFloat(self.vm.gridScrollOffset))"),
            "the grid must restore the saved offset via ScrollPosition"
        )
    }
}
