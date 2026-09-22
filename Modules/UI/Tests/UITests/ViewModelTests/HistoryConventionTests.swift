import Foundation
import Testing

// MARK: - HistoryConventionTests

/// Source-convention checks for the History destination (ADR-094) that
/// cannot run host-less: the sidebar row, the content routing, and the one
/// thing the page must never gain.
@Suite("History conventions")
struct HistoryConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The sidebar lists History in the Recents section, after Most Played")
    func sidebarRowInRecents() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        let mostPlayed = try #require(sidebar.range(of: "self.sidebarRow(.mostPlayed"))
        let history = try #require(sidebar.range(of: "self.sidebarRow(.history"))
        #expect(mostPlayed.lowerBound < history.lowerBound, "History follows Most Played")
        // Both sit inside the same expansion gate, so collapsing Recents hides both.
        let between = sidebar[mostPlayed.lowerBound ..< history.lowerBound]
        #expect(!between.contains("Section {"), "History must be in the Recents section, not its own")
        #expect(sidebar.contains("A11y.Sidebar.history"), "the row must carry its identifier (ADR-081)")
    }

    @Test("The content pane routes .history to HistoryView on the shared view model")
    func contentPaneRoutesHistory() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(pane.contains("case .history:"))
        #expect(pane.contains("HistoryView(vm: self.vm.history, library: self.vm)"))
    }

    @Test("Nothing on the History page takes keyboard focus")
    func historyPageTakesNoFocus() throws {
        // A .focusable() view torn down while focused makes the window swallow
        // right-clicks before the table sees them (docs/GOTCHAS.md); the page
        // is an AppKit table that handles its own focus.
        for file in ["History/HistoryView.swift", "History/HistoryTable.swift", "History/HistoryTableCoordinator.swift"] {
            let text = try self.source(file)
            #expect(!text.contains(".focusable("), "\(file) must not add .focusable()")
            #expect(!text.contains("@FocusState"), "\(file) must not hold focus state")
        }
    }

    @Test("A scan that added songs re-matches the imported listens, and a scan that did not leaves them alone")
    func scanRematchesImportedListens() throws {
        let scanning = try self.source("ViewModels/LibraryViewModel+Scanning.swift")
        let finished = try #require(scanning.range(of: "case let .finished(summary):"))
        let hook = try #require(scanning.range(of: "await self.rematchImportedListensAfterScan()"))
        #expect(finished.lowerBound < hook.lowerBound, "the re-match runs from the finished handler")
        let between = scanning[finished.lowerBound ..< hook.lowerBound]
        #expect(between.contains("if summary.inserted > 0 {"), "gated on the scan having added songs")
        let listenImport = try self.source("ViewModels/LibraryViewModel+ListenImport.swift")
        let start = try #require(listenImport.range(of: "func rematchImportedListensAfterScan() async"))
        let rest = listenImport[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        #expect(body.contains("rematch()"), "it runs the existing re-match pass")
        #expect(!body.contains("showToast"), "the scan's re-match is quiet: no toast mid-scan")
    }

    @Test("The toolbar search field and type-to-search both go through the routed accessor")
    func searchFieldIsRouted() throws {
        // A revert to `searchQuery` here would silently undo slice 2: the
        // field would stop feeding History and start writing the library
        // query from that page.
        let root = try self.source("AppRoot/RootView.swift")
        #expect(root.contains(".searchable(text: self.$vm.searchText"))
        #expect(!root.contains(".searchable(text: self.$vm.searchQuery"))
        let typeToSearch = try self.source("AppRoot/TypeToSearchMonitor.swift")
        #expect(typeToSearch.contains("self.vm.searchText = String(char)"))
        #expect(!typeToSearch.contains("self.vm.searchQuery = String(char)"))
    }
}
