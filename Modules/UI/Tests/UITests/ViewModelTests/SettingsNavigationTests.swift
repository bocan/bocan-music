import Foundation
import Testing
@testable import UI

// MARK: - SettingsNavigationTests

/// Covers the Settings reorganization and deep-link router (#305): every page is
/// reachable from exactly one sidebar section, Sources is always shown, the audio
/// panes are grouped under Playback, and the router queues deep-links reliably.
@Suite("Settings navigation")
@MainActor
struct SettingsNavigationTests {
    // MARK: SettingsRouter

    @Test("open(_:) queues a page with no payload (#305)")
    func routerOpensPage() {
        let router = SettingsRouter()
        #expect(router.pendingPage == nil)
        router.open(.appearance)
        #expect(router.pendingPage == .appearance)
        #expect(router.pendingServerID == nil)
    }

    @Test("open(.sources, serverID:) carries the server payload (#305)")
    func routerOpensSourcesWithServer() {
        let router = SettingsRouter()
        let id = UUID()
        router.open(.sources, serverID: id)
        #expect(router.pendingPage == .sources)
        #expect(router.pendingServerID == id)
    }

    // MARK: Sidebar sections

    @Test("Every SettingsPage is in exactly one sidebar section (#305)")
    func everyPageIsReachable() {
        // Scrobbling is conditional; with it included, all 14 pages must appear
        // exactly once across the sections — no page orphaned from the sidebar.
        let pages = SettingsSection.sidebar(includeScrobble: true).flatMap(\.pages)
        for page in SettingsPage.allCases {
            #expect(pages.count { $0 == page } == 1, "\(page) must appear exactly once in the sidebar")
        }
    }

    @Test("Sources is always shown, even without scrobbling (#305)")
    func sourcesAlwaysShown() {
        let pages = SettingsSection.sidebar(includeScrobble: false).flatMap(\.pages)
        #expect(pages.contains(.sources), "Sources must always be in the sidebar so server setup is findable")
    }

    @Test("Scrobbling appears only when its provider exists (#305)")
    func scrobbleIsConditional() {
        #expect(!SettingsSection.sidebar(includeScrobble: false).flatMap(\.pages).contains(.scrobble))
        #expect(SettingsSection.sidebar(includeScrobble: true).flatMap(\.pages).contains(.scrobble))
    }

    @Test("The audio panes are grouped together under Playback (#305)")
    func audioPanesGroupedUnderPlayback() throws {
        let sections = SettingsSection.sidebar(includeScrobble: true)
        let playback = try #require(sections.first { $0.title == "Playback" })
        for page in [SettingsPage.playback, .equaliser, .effects, .replayGain] {
            #expect(playback.pages.contains(page), "Playback section should contain \(page)")
        }
    }

    // MARK: Presentation

    @Test("Every page has a non-empty title and SF Symbol (#305)")
    func everyPageHasLabelAndIcon() {
        for page in SettingsPage.allCases {
            #expect(!page.title.isEmpty, "\(page) has an empty title")
            #expect(!page.systemImage.isEmpty, "\(page) has an empty systemImage")
        }
    }
}
