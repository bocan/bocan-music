import Foundation
import Testing
@testable import UI

// MARK: - HelpContentTests

/// The Help window is the only help text the app ships. Its strings reach
/// `L10n` through variables, so neither Xcode's extraction nor the bare-literal
/// lint rule sees them; these tests are the guard.
@Suite("Help window content")
struct HelpContentTests {
    private func catalog() throws -> [String: Any] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    @Test("Every help string has a catalog entry with a pseudolocale value")
    func everyStringIsInTheCatalog() throws {
        let strings = try self.catalog()
        let missing = HelpContent.allKeys.filter { key in
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            return localizations?["en-XA"] == nil
        }
        #expect(missing.isEmpty, "Help strings missing from Localizable.xcstrings (add them, then make pseudolocale): \(missing)")
    }

    @Test("Every page has something to show")
    func everyPageHasContent() {
        for section in HelpSection.allCases where section != .shortcuts && section != .formats {
            #expect(!HelpContent.topics(for: section).isEmpty, "\(section.title) has no topics")
        }
        #expect(!HelpShortcuts.groups.isEmpty)
        #expect(!HelpContent.formatRows.isEmpty)
    }

    @Test("Topic titles are unique within a page, because the list uses them as identity")
    func topicTitlesAreUnique() {
        for section in HelpSection.allCases {
            let titles = HelpContent.topics(for: section).map(\.title)
            #expect(Set(titles).count == titles.count, "\(section.title) repeats a topic title")
        }
        let actions = HelpShortcuts.groups.flatMap(\.shortcuts).map(\.action)
        #expect(Set(actions).count == actions.count)
    }

    @Test("Back and Forward are documented with their bracket shortcuts")
    func backForwardDocumented() {
        let rows = HelpShortcuts.groups.flatMap(\.shortcuts)
        #expect(rows.contains(HelpShortcut(action: "Back", key: "⌘[")))
        #expect(rows.contains(HelpShortcut(action: "Forward", key: "⌘]")))
    }

    @Test("The scrobbling topics name the three services the app supports")
    func scrobblingNamesTheRightServices() {
        let bodies = HelpContent.allKeys.filter { $0.contains("Last.fm") }
        #expect(bodies.count == 2)
        for body in bodies {
            #expect(body.contains("ListenBrainz") && body.contains("Rocksky"))
            #expect(!body.localizedCaseInsensitiveContains("MusicBrainz"))
        }
    }

    /// Statements the 2026-10 audit found in the help and the code contradicts.
    @Test(
        "A statement the audit proved wrong does not come back",
        arguments: [
            "Window → Toggle Miniplayer", // the item is in the View menu
            "CAF", // the scanner does not accept .caf
            "range requests", // Subsonic tracks download completely first
            "up to nine", // the code has no server limit
            "blue pulsing", // connecting shows a spinner
            "Settings → Podcasts → Refresh", // auto-download is not in that section
        ]
    )
    func provenWrongStatementsStayOut(statement: String) {
        let offenders = HelpContent.allKeys.filter { $0.contains(statement) }
        #expect(offenders.isEmpty, "help text says \"\(statement)\" again: \(offenders)")
    }

    @Test("Podcasts and Internet Radio have their own pages")
    func podcastsAndRadioArePages() {
        #expect(HelpSection.allCases.contains(.podcasts))
        #expect(HelpSection.allCases.contains(.internetRadio))
        #expect(HelpContent.podcasts.map(\.title).contains("Subscribing to a podcast"))
        #expect(HelpContent.internetRadio.map(\.title).contains("Adding a station"))
    }
}
