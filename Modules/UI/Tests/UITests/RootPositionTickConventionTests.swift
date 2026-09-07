import Foundation
import Testing
@testable import UI

// MARK: - RootPositionTickConventionTests

/// Source-convention checks for #450: the 0.5 s playback position tick must not
/// invalidate `BocanRootView.body`. A `nowPlaying.position` read in the root
/// body makes the whole body a dependent of the tick, every child that cannot
/// prove itself unchanged re-runs with it, and the songs table re-diffs every
/// row twice a second (measured: 77 hitches over 100 ms in 45 s). Observation
/// scope cannot be exercised host-less, so these assert the wiring.
@Suite("Root position tick source conventions")
struct RootPositionTickConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines of code only: comments explaining the rule may name the property.
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("BocanRootView.body never reads nowPlaying.position")
    func rootBodyDoesNotReadPosition() throws {
        let source = try self.source("Sources/UI/AppRoot/RootView.swift")
        let offenders = self.codeLines(source).filter { $0.contains("nowPlaying.position") }
        #expect(offenders.isEmpty, "root body reads the position tick: \(offenders)")
    }

    @Test("LyricsPane takes the transport model, not a position value")
    func lyricsPaneTakesModel() throws {
        let source = try self.source("Sources/UI/Lyrics/LyricsPane.swift")
        #expect(source.contains("nowPlaying: NowPlayingViewModel"))
        #expect(!self.codeLines(source).contains { $0.contains("position: TimeInterval") })
    }

    @Test("LyricsPane reads the position only inside the editor sheet content")
    func lyricsPanePositionReadIsInsideSheet() throws {
        let source = try self.source("Sources/UI/Lyrics/LyricsPane.swift")
        let reads = self.codeLines(source).filter { $0.contains("nowPlaying.position") }
        #expect(reads.count == 1, "expected exactly one position read: \(reads)")
        let sheet = try #require(source.range(of: ".sheet(isPresented: self.$vm.isEditorPresented)"))
        let read = try #require(source.range(of: "currentPosition: self.nowPlaying.position"))
        #expect(sheet.lowerBound < read.lowerBound)
    }

    @Test("LyricsPlaybackDriver still forwards each position tick to the lyrics model")
    func driverForwardsPosition() throws {
        let source = try self.source("Sources/UI/Lyrics/LyricsPlaybackDriver.swift")
        #expect(source.contains(".onChange(of: self.nowPlaying.position)"))
        #expect(source.contains("self.lyricsVM.positionDidChange(position)"))
    }
}
