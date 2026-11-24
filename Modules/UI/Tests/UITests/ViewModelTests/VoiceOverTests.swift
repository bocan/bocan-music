import Foundation
import Testing

// MARK: - VoiceOverTests

/// Verifies VoiceOver accessibility support added in Phase 1.
///
/// Source-convention checks that key a11y modifiers exist in UI source files.
/// The cell that speaks a table row's status is covered by `TableRowStatusTests`.
@Suite("VoiceOver Accessibility")
struct VoiceOverTests {
    // MARK: - Helpers

    /// Root of the UI package Sources directory.
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func sourceContents(at relativePath: String) throws -> String {
        let url = self.uiSourcesURL.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Source convention: album cell hints

    @Test("AlbumsGridView AlbumCell has accessibilityHint for opening album")
    func albumsGridViewHasOpenHint() throws {
        let source = try self.sourceContents(at: "Browse/AlbumsGridView.swift")
        // Copy may be wrapped in L10n.string(...) for localization (#314); match the text itself.
        #expect(
            source.contains("accessibilityHint(L10n.string(\"Double-tap to open album\"))")
                || source.contains("accessibilityHint(\"Double-tap to open album\")"),
            "AlbumCell must declare the Double-tap to open album accessibility hint"
        )
    }

    @Test("ArtistsView album cell has accessibilityHint for opening album")
    func artistsViewAlbumCellHasOpenHint() throws {
        let source = try self.sourceContents(at: "Browse/ArtistsView.swift")
        // Copy may be wrapped in L10n.string(...) for localization (#314); match the text itself.
        #expect(
            source.contains("accessibilityHint(L10n.string(\"Double-tap to open album\"))")
                || source.contains("accessibilityHint(\"Double-tap to open album\")"),
            "ArtistsView album cell must declare the Double-tap to open album accessibility hint"
        )
    }

    @Test("ArtistsView artist row uses .combine accessibility element")
    func artistsViewArtistRowUsesCombine() throws {
        let source = try self.sourceContents(at: "Browse/ArtistsView.swift")
        #expect(
            source.contains("accessibilityElement(children: .combine)"),
            "ArtistsView artist list rows must use .accessibilityElement(children: .combine)"
        )
    }

    // MARK: - Source convention: NowPlayingStrip

    @Test("NowPlayingStrip announces track changes to VoiceOver")
    func nowPlayingStripHasLiveAnnouncement() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("announcementRequested"),
            "NowPlayingStrip must post .announcementRequested on track change"
        )
    }

    @Test("NowPlayingStrip title has updatesFrequently trait")
    func nowPlayingStripTitleHasUpdatesFrequently() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains(".updatesFrequently"),
            "NowPlayingStrip title button must carry .accessibilityAddTraits(.updatesFrequently)"
        )
    }

    @Test("NowPlayingStrip volume slider has accessibilityValue")
    func nowPlayingStripVolumeHasValue() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("percent"),
            "Volume slider must expose percentage as accessibilityValue"
        )
    }

    // MARK: - Source convention: EQ band sliders

    @Test("EQView band sliders use .1f dB format in accessibilityValue")
    func eqBandSliderAccessibilityValueFormat() throws {
        let source = try self.sourceContents(at: "DSP/EQView.swift")
        // Look for the BandSliderView's .1f format (not the .0f that was there before)
        #expect(
            source.contains("%+.1f dB"),
            "BandSliderView must use \"%+.1f dB\" format in accessibilityValue"
        )
    }

    // MARK: - Source convention: table rows

    @Test("No table implements accessibilityLabelForRow, which AppKit never calls (#694)")
    func noCoordinatorHasDeadRowLabelMethod() throws {
        for file in [
            "Browse/TrackTableCoordinator.swift",
            "History/HistoryTableCoordinator.swift",
            "Browse/Subsonic/SubsonicSongTableCoordinator.swift",
            "Browse/Jellyfin/JellyfinSongTableCoordinator.swift",
        ] {
            let source = try self.sourceContents(at: file)
            #expect(!source.contains("accessibilityLabelForRow"), "\(file): put row status on a cell instead")
        }
    }

    // MARK: - Differentiate Without Color (#298)

    @Test("ActiveToggleIndicator reads accessibilityDifferentiateWithoutColor")
    func activeToggleIndicatorReadsDifferentiateWithoutColor() throws {
        let source = try self.sourceContents(at: "Theme/ActiveToggleIndicator.swift")
        #expect(
            source.contains("accessibilityDifferentiateWithoutColor"),
            "ActiveToggleIndicator must gate its shape affordance on accessibilityDifferentiateWithoutColor"
        )
    }

    @Test("NowPlayingStrip transport toggles apply activeToggleIndicator")
    func nowPlayingStripTogglesUseActiveIndicator() throws {
        // Transport controls were extracted to MusicTransportControls.swift in phase 21-10.
        let source = try self.sourceContents(at: "Transport/MusicTransportControls.swift")
        #expect(
            source.contains("activeToggleIndicator"),
            "Shuffle/repeat/stop-after toggles must apply .activeToggleIndicator so on/off isn't colour-only"
        )
    }

    @Test("SubsonicStatusDot reads accessibilityDifferentiateWithoutColor")
    func subsonicStatusDotReadsDifferentiateWithoutColor() throws {
        let source = try self.sourceContents(at: "AppRoot/SubsonicSidebarSection.swift")
        #expect(
            source.contains("accessibilityDifferentiateWithoutColor"),
            "SubsonicStatusDot must render a per-status glyph when differentiate-without-colour is on"
        )
    }
}
