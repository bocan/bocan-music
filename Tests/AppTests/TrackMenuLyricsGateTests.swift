import Foundation
import Testing

// MARK: - TrackMenuLyricsGateTests

/// Guards the #546 fix. `BocanCommands` holds `LyricsViewModel` (an
/// `ObservableObject`) as a plain `let`, so a `.disabled` gate that reads one of
/// its `@Published` values freezes at whatever it was when the menu was built.
/// The Fetch Lyrics and Clear Lyrics gates must read the `@Observable`
/// `menuState` instead (`docs/GOTCHAS.md`, "Gate menu items only on
/// `@AppStorage` or `@Observable` reads").
@Suite("Track menu lyrics gates (#546)")
struct TrackMenuLyricsGateTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands+Track.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `.disabled(...)` lines only: comments may name the old properties.
    private func gateLines(_ source: String) -> [String] {
        source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".disabled(") }
    }

    @Test("the gates read the @Observable menu state")
    func gatesReadMenuState() throws {
        let gates = try self.gateLines(self.commandsSource())
        #expect(gates.contains { $0.contains("lyricsVM.menuState.isFetching") }, "Fetch Lyrics gate")
        #expect(gates.contains { $0.contains("lyricsVM.menuState.hasDocument") }, "Clear Lyrics gate")
    }

    @Test("no gate reads a @Published value of the lyrics model")
    func noGateReadsPublishedLyricsState() throws {
        let gates = try self.gateLines(self.commandsSource())
        let offenders = gates.filter { line in
            line.contains("lyricsVM.") && !line.contains("lyricsVM.menuState.")
        }
        #expect(offenders.isEmpty, "these gates would freeze: \(offenders)")
    }
}
