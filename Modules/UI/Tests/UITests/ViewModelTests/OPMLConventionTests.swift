import Foundation
import Testing
@testable import UI

// MARK: - OPMLConventionTests

/// Source-convention guards for the Phase 21-12-g OPML import/export UI: the
/// menu, panels, and import sheet cannot be exercised host-less, so we assert
/// their structure by reading source.
@Suite("OPML Import/Export Convention")
struct OPMLConventionTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Home view exposes localized Import/Export menu items wired to OPML panels")
    func homeMenu() throws {
        let home = try self.source("Browse/Podcasts/PodcastsHomeView.swift")
        #expect(home.contains("Import Subscriptions…"))
        #expect(home.contains("Export Subscriptions…"))
        #expect(home.contains("NSOpenPanel"))
        #expect(home.contains("NSSavePanel"))
        #expect(home.contains("vm.exportOPML()"))
        #expect(home.contains("options: .atomic"))
        #expect(home.contains("No subscriptions to export"))
    }

    @Test("Import sheet shows determinate progress, lists failures, and toasts success")
    func importSheet() throws {
        let sheet = try self.source("Browse/Podcasts/PodcastOPMLImportSheet.swift")
        #expect(sheet.contains("ProgressView(value:"))
        #expect(sheet.contains("vm.importOPML(data:"))
        #expect(sheet.contains("summary.failed"))
        #expect(sheet.contains("library.showToast"))
    }
}
