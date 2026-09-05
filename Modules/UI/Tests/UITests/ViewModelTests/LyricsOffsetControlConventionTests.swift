import Foundation
import Testing
@testable import UI

// MARK: - LyricsOffsetControlConventionTests

/// ADR-089 slice 2: the sync-offset popover lives in one shared control, and
/// the lyrics view model's position ticks are driven from the root, not from
/// inside the pane, so a second surface (the Immersive Mode lyrics column)
/// sees the same document with the same highlight. Source conventions,
/// because the popover and the root view cannot be exercised host-less.
@Suite("LyricsOffsetControl conventions")
struct LyricsOffsetControlConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the control owns the offset button, the slider, its range and the commit on dismiss")
    func controlOwnsTheOffsetUI() throws {
        let control = try self.source("Lyrics/LyricsOffsetControl.swift")
        #expect(control.contains("A11y.Lyrics.offsetButton"))
        #expect(control.contains("A11y.Lyrics.offsetSlider"))
        #expect(control.contains("in: -5000 ... 5000, step: 50"))
        #expect(control.contains("self.vm.commitOffset()"))
    }

    @Test("the pane embeds the shared control instead of its own copy")
    func paneEmbedsTheControl() throws {
        let pane = try self.source("Lyrics/LyricsPane.swift")
        #expect(pane.contains("LyricsOffsetControl(vm: self.vm)"))
        #expect(!pane.contains("A11y.Lyrics.offsetSlider"))
        #expect(!pane.contains("showOffsetPopover"))
    }

    @Test("track and position ticks reach the lyrics view model from the root driver, not the pane")
    func positionIsDrivenFromRoot() throws {
        let root = try self.source("AppRoot/RootView.swift")
        let driver = try self.source("Lyrics/LyricsPlaybackDriver.swift")
        let pane = try self.source("Lyrics/LyricsPane.swift")
        #expect(root.contains("LyricsPlaybackDriver(lyricsVM: self.lyricsVM, nowPlaying: self.vm.nowPlaying)"))
        #expect(driver.contains(".onChange(of: self.nowPlaying.nowPlayingTrackID)"))
        #expect(driver.contains(".onChange(of: self.nowPlaying.position)"))
        #expect(driver.contains("self.lyricsVM.trackDidChange(trackID: trackID)"))
        #expect(driver.contains("self.lyricsVM.positionDidChange(position)"))
        #expect(!pane.contains("positionDidChange"))
        #expect(!root.contains("positionDidChange"))
    }
}
