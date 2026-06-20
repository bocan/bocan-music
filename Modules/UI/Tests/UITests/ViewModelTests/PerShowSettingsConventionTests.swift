import Foundation
import Testing
@testable import UI

// MARK: - PerShowSettingsConventionTests

/// Tests for the Phase 21-12-h per-show settings: the pure rate resolver and a
/// source-convention check on the settings sheet (which cannot run host-less).
@Suite("Per-Show Settings")
struct PerShowSettingsConventionTests {
    @Test("resolvePodcastRate: per-show speed wins, else global, else 1.0, clamped to [0.5, 2.0]")
    func rateResolver() {
        #expect(NowPlayingViewModel.resolvePodcastRate(showSpeed: 1.5, globalRate: 1.25) == 1.5)
        #expect(NowPlayingViewModel.resolvePodcastRate(showSpeed: nil, globalRate: 1.25) == 1.25)
        #expect(NowPlayingViewModel.resolvePodcastRate(showSpeed: nil, globalRate: 0) == 1.0)
        #expect(NowPlayingViewModel.resolvePodcastRate(showSpeed: 5.0, globalRate: 0) == 2.0)
        #expect(NowPlayingViewModel.resolvePodcastRate(showSpeed: 0.1, globalRate: 0) == 0.5)
    }

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

    @Test("the settings sheet exposes the four controls with default-to-nil mapping")
    func sheetControls() throws {
        let sheet = try self.source("Browse/Podcasts/PodcastShowSettingsView.swift")
        #expect(sheet.contains("Playback Speed"))
        #expect(sheet.contains("Episode Order"))
        #expect(sheet.contains("Keep Episodes"))
        #expect(sheet.contains("Auto-Download New Episodes"))
        #expect(sheet.contains("App Default"))
        #expect(sheet.contains("Double?.none"), "App Default maps to nil")
        #expect(sheet.contains("vm.setPlaybackSpeed"))
        #expect(sheet.contains("vm.setEpisodeSort"))
        #expect(sheet.contains("vm.setRetentionLimit"))
    }
}
