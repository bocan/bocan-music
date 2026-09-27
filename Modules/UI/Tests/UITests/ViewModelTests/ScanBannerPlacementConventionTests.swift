import Foundation
import Testing

// MARK: - ScanBannerPlacementConventionTests

/// The scan banner floats over the content instead of sitting in a
/// safe-area inset. The inset resized the content, so every row of the list
/// moved when the banner came or went, and a double-click that straddled its
/// auto-hide played the song under the one clicked (an E2E run, 2026-09-27).
/// A source convention, because the content pane cannot be rendered
/// host-less.
@Suite("Scan banner placement")
struct ScanBannerPlacementConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the content pane mounts the scan banner in a bottom overlay, not a safe-area inset")
    func bannerIsAnOverlay() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        let banner = try #require(pane.range(of: "ScanBanner(vm: self.vm)"))
        let before = pane[pane.startIndex ..< banner.lowerBound]
        let overlay = try #require(before.range(of: ".overlay(alignment: .bottom)", options: .backwards))
        let inset = before.range(of: ".safeAreaInset(", options: .backwards)
        // The closest container above the banner is the overlay.
        #expect(inset.map { $0.lowerBound < overlay.lowerBound } ?? true)
    }
}
