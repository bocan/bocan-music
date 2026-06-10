import Foundation
import Testing

// MARK: - RecentScrobblesConventionTests

/// Source-convention checks for the recent-scrobbles observation lifecycle.
///
/// `RecentScrobblesView` is presented both from `ScrobbleSettingsView` and from
/// the `NowPlayingStrip` pending-scrobbles indicator. The strip path used to
/// show an empty "No Scrobbles Yet" state because only the settings pane ever
/// started the view model's `observeRecent` stream. These tests assert the two
/// structural facts that keep that fixed: the view drives `appear()`/
/// `disappear()` itself, and the view model reference-counts observers so a
/// sheet dismissing over a still-visible settings pane does not cancel the
/// pane's streams.
@Suite("RecentScrobblesView observation conventions")
struct RecentScrobblesConventionTests {
    // MARK: - Helpers

    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        let url = self.uiSourcesURL.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tests

    @Test("RecentScrobblesView starts the observation streams on appear")
    func viewCallsAppear() throws {
        let source = try self.source("Scrobble/RecentScrobblesView.swift")
        #expect(
            source.contains(".onAppear { self.viewModel.appear() }"),
            "RecentScrobblesView must call viewModel.appear() so the recent list populates when presented from any surface"
        )
    }

    @Test("RecentScrobblesView stops the observation streams on disappear")
    func viewCallsDisappear() throws {
        let source = try self.source("Scrobble/RecentScrobblesView.swift")
        #expect(
            source.contains(".onDisappear { self.viewModel.disappear() }"),
            "RecentScrobblesView must balance appear() with viewModel.disappear()"
        )
    }

    @Test("Subsonic submission status is visible in the list")
    func subsonicStatusVisible() throws {
        let source = try self.source("Scrobble/RecentScrobblesView.swift")
        #expect(
            source.contains("\"lastfm\", \"listenbrainz\", \"rocksky\", \"subsonic\""),
            "Subsonic must be in the default badge list; a subsonic-only queue row otherwise renders with no status at all"
        )
        #expect(
            source.contains("case \"subsonic\":"),
            "providerDisplayName must map the subsonic provider id"
        )
    }

    @Test("Provider filter segments derive from the loaded history")
    func filterSegmentsAreDynamic() throws {
        let source = try self.source("Scrobble/RecentScrobblesView.swift")
        #expect(
            source.contains("flatMap(\\.statusByProvider.keys)"),
            "Filter segments must come from providers present in the history, so an unused provider shows no segment"
        )
        #expect(
            source.contains("self.filter = .all"),
            "The selected filter must fall back to All when its provider vanishes from the live-updating history"
        )
    }

    @Test("ScrobbleSettingsViewModel reference-counts observers")
    func viewModelReferenceCountsObservers() throws {
        let source = try self.source("Scrobble/ScrobbleSettingsViewModel.swift")
        #expect(
            source.contains("observerCount"),
            "ScrobbleSettingsViewModel must reference-count appear()/disappear() so nested surfaces do not cancel each other's streams"
        )
        #expect(
            source.contains("guard self.observerCount == 0 else { return }"),
            "disappear() must only cancel the streams once the last observing surface goes away"
        )
    }
}
