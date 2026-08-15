import Foundation
import Testing

// MARK: - HelpShortcutParityTests

/// The keyboard-shortcut reference exists twice: the in-app Help window
/// (`App/HelpWindowView.swift`) and the Apple Help Book
/// (`HelpBook/…/index.html`). Both are hand-maintained, and they drifted
/// badly once already (four contradictory entries). This suite parses both
/// tables and fails on any difference, so an edit to one without the other
/// reddens the build.
@Suite("Help shortcut parity")
struct HelpShortcutParityTests {
    private struct Row: Equatable, CustomStringConvertible {
        let action: String
        let key: String

        var description: String {
            "\(self.action) → \(self.key)"
        }
    }

    private var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }

    private func swiftRows() throws -> [Row] {
        let url = self.repoRoot.appendingPathComponent("App/HelpWindowView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = /Shortcut\(action: "([^"]+)", key: "([^"]+)"\)/
        return source.matches(of: pattern).map { Row(action: String($0.1), key: String($0.2)) }
    }

    private func htmlRows() throws -> [Row] {
        let url = self.repoRoot
            .appendingPathComponent("HelpBook/Bocan.help/Contents/Resources/en.lproj/index.html")
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = /<tr><td>([^<]+)<\/td><td>([^<]+)<\/td><\/tr>/
        return source.matches(of: pattern).map {
            Row(
                action: String($0.1).replacingOccurrences(of: "&amp;", with: "&"),
                key: String($0.2)
            )
        }
    }

    @Test("The in-app table and the Help Book table list identical rows in order")
    func tablesMatch() throws {
        let swift = try self.swiftRows()
        let html = try self.htmlRows()
        #expect(!swift.isEmpty, "no Shortcut(action:key:) rows parsed from HelpWindowView.swift")
        #expect(swift.count == html.count, "row counts differ: app \(swift.count) vs book \(html.count)")
        for (appRow, bookRow) in zip(swift, html) where appRow != bookRow {
            Issue.record("mismatch: app '\(appRow)' vs book '\(bookRow)'")
        }
    }

    @Test("Back and Forward are documented with their bracket shortcuts")
    func backForwardDocumented() throws {
        let rows = try self.swiftRows()
        #expect(rows.contains(Row(action: "Back", key: "⌘[")))
        #expect(rows.contains(Row(action: "Forward", key: "⌘]")))
    }
}
