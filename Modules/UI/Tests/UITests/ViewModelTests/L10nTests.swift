import Foundation
import Testing
@testable import UI

// MARK: - L10nTests

/// Guards the localization foundation laid in #314.
///
/// Note on harness: pure SwiftPM (`swift test` / `make test-ui`) only *copies*
/// `Localizable.xcstrings`; it does not compile it into runtime `.strings` /
/// `.stringsdict`, so `String(localized:bundle:.module)` falls back to the key
/// there. The Xcode build *does* compile it (verified: the app bundle ships
/// `en.lproj/Localizable.stringsdict` with the correct plural rules). So rather
/// than assert runtime resolution — which is build-system dependent — these tests
/// validate the catalog *content* (the source of truth) and the wiring, both of
/// which are deterministic in either harness.
@Suite("Localization (L10n)")
struct L10nTests {
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

    /// Extracts the `(one, other)` plural variation values for `key` from the catalog.
    private func plural(_ key: String, in strings: [String: Any]) -> (one: String, other: String)? {
        guard let entry = strings[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let en = locs["en"] as? [String: Any],
              let variations = en["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any],
              let one = (plural["one"] as? [String: Any])?["stringUnit"] as? [String: Any],
              let other = (plural["other"] as? [String: Any])?["stringUnit"] as? [String: Any],
              let oneVal = one["value"] as? String,
              let otherVal = other["value"] as? String else { return nil }
        return (oneVal, otherVal)
    }

    @Test("Catalog contains the simple reference-screen keys (#314)")
    func catalogHasSimpleKeys() throws {
        let strings = try self.catalog()
        for key in ["Albums", "Various Artists", "Force Gapless Playback", "Add Music Folder"] {
            #expect(strings[key] != nil, "Catalog missing key: \(key)")
        }
    }

    @Test("'Play %lld Albums' pluralizes: one collapses to 'Play Album' (#314)")
    func playAlbumsPlural() throws {
        let variation = try #require(self.plural("Play %lld Albums", in: self.catalog()))
        #expect(variation.one == "Play Album")
        #expect(variation.other == "Play %lld Albums")
    }

    @Test("'%lld songs' pluralizes to a singular noun for one (#314)")
    func songsPlural() throws {
        let variation = try #require(self.plural("%lld songs", in: self.catalog()))
        #expect(variation.one == "%lld song")
        #expect(variation.other == "%lld songs")
    }

    @Test("Get Info / Remove context actions pluralize (#314)")
    func contextActionPlurals() throws {
        let strings = try self.catalog()
        let getInfo = try #require(self.plural("Get Info (%lld Albums)", in: strings))
        #expect(getInfo.one == "Get Info")
        let remove = try #require(self.plural("Remove %lld Albums from Library", in: strings))
        #expect(remove.one == "Remove Album from Library")
    }

    @Test("'%lld unplayed episodes' pluralizes for the unread-badge a11y label")
    func unplayedEpisodesPlural() throws {
        let variation = try #require(self.plural("%lld unplayed episodes", in: self.catalog()))
        #expect(variation.one == "%lld unplayed episode")
        #expect(variation.other == "%lld unplayed episodes")
    }

    /// Module root (`Modules/UI/`) derived from this test file's path.
    private var moduleRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
    }

    @Test("UI package declares a default localization so the catalog is compiled (#314)")
    func packageDeclaresDefaultLocalization() throws {
        let url = self.moduleRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("defaultLocalization:"), "Package.swift must set defaultLocalization for the catalog to compile")
    }

    @Test("Clear-queue alert message pluralizes (#314)")
    func clearQueuePlural() throws {
        let variation = try #require(
            self.plural("This removes the %lld tracks in your queue and stops playback.", in: self.catalog())
        )
        #expect(variation.one == "This removes the %lld track in your queue and stops playback.")
        #expect(variation.other == "This removes the %lld tracks in your queue and stops playback.")
    }

    @Test("Browse plural keys collapse to singular forms (#314)")
    func browsePlurals() throws {
        let strings = try self.catalog()
        let albums = try #require(self.plural("%lld albums", in: strings))
        #expect(albums.one == "%lld album")
        let stars = try #require(self.plural("%lld stars", in: strings))
        #expect(stars.one == "%lld star")
        let removeAlbums = try #require(self.plural("Remove %lld albums from library?", in: strings))
        #expect(removeAlbums.one == "Remove %lld album from library?")
    }

    @Test("'Keep %lld backups' stepper pluralizes (#314)")
    func keepBackupsPlural() throws {
        let variation = try #require(self.plural("Keep %lld backups", in: self.catalog()))
        #expect(variation.one == "Keep %lld backup")
        #expect(variation.other == "Keep %lld backups")
    }

    @Test("Phase 4 plural keys collapse to singular forms (#314)")
    func phase4Plurals() throws {
        let strings = try self.catalog()
        let analysed = try #require(self.plural("Analysis complete — %lld tracks analysed", in: strings))
        #expect(analysed.one == "Analysis complete — %lld track analysed")
        let errors = try #require(self.plural("%lld errors", in: strings))
        #expect(errors.one == "%lld error")
        let groups = try #require(self.plural("%lld groups found", in: strings))
        #expect(groups.one == "%lld group found")
        let images = try #require(self.plural("Done — %lld images saved", in: strings))
        #expect(images.one == "Done — %lld image saved")
    }

    @Test(
        "Phase 4 areas route copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/DSP/EQView.swift",
            "Sources/UI/DSP/DSPView.swift",
            "Sources/UI/DSP/ReplayGainSettingsView.swift",
            "Sources/UI/Scrobble/ConnectSheet.swift",
            "Sources/UI/Scrobble/ScrobbleSettingsView.swift",
            "Sources/UI/Scrobble/RecentScrobblesView.swift",
            "Sources/UI/Fingerprint/CandidatePickerView.swift",
            "Sources/UI/Fingerprint/IdentifyTrackSheet.swift",
            "Sources/UI/Tools/BatchCoverArtSheet.swift",
            "Sources/UI/Tools/DuplicateReviewSheet.swift",
            "Sources/UI/Visualizers/VisualizerSettingsView.swift",
            "Sources/UI/Visualizers/VisualizerPane.swift",
            "Sources/UI/PlaylistIO/PlaylistImportSheet.swift",
            "Sources/UI/PlaylistIO/PlaylistExportSheet.swift",
            "Sources/UI/Import/ScanBanner.swift",
        ]
    )
    func phase4AreasUseHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test("Up Next toast pluralizes (#314)")
    func upNextToastPlural() throws {
        let variation = try #require(self.plural("Added %lld songs to Up Next", in: self.catalog()))
        #expect(variation.one == "Added %lld song to Up Next")
        #expect(variation.other == "Added %lld songs to Up Next")
    }

    @Test(
        "View-model copy routes through the localization helper (#314)",
        arguments: [
            "Sources/UI/ViewModels/LibraryViewModel.swift",
            "Sources/UI/ViewModels/LibraryViewModel+Delete.swift",
            "Sources/UI/ViewModels/LibraryViewModel+Scanning.swift",
            "Sources/UI/ViewModels/LibraryViewModel+Subsonic.swift",
            "Sources/UI/ViewModels/LibraryViewModel+PlaylistDrop.swift",
            "Sources/UI/ViewModels/NowPlayingViewModel.swift",
            "Sources/UI/ViewModels/TracksViewModel.swift",
            "Sources/UI/Visualizers/ViewModels/VisualizerViewModel.swift",
        ]
    )
    func viewModelCopyUsesHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test("Phase 5 plural keys collapse to singular forms (#314)")
    func phase5Plurals() throws {
        let strings = try self.catalog()
        let lines = try #require(self.plural("%lld lines", in: strings))
        #expect(lines.one == "1 line")
        let tracks = try #require(self.plural("%lld tracks", in: strings))
        #expect(tracks.one == "%lld track")
        let artists = try #require(self.plural("%lld artists", in: strings))
        #expect(artists.one == "%lld artist")
        let remove = try #require(self.plural("Remove %lld tracks from library?", in: strings))
        #expect(remove.one == "Remove %lld track from library?")
    }

    @Test(
        "Last unconverted surfaces route copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Common/TrackInfoPanel.swift",
            "Sources/UI/Console/LogConsoleView.swift",
            "Sources/UI/Theme/ContrastAudit.swift",
            "Sources/UI/Theme/ThemeAudit.swift",
            "Sources/UI/Playlists/PlaylistHeader.swift",
        ]
    )
    func phase5SurfacesUseHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    /// Flattens a localization entry to its concrete display values, keyed by
    /// plural category ("=" for a plain stringUnit).
    private func values(of localization: [String: Any]?) -> [String: String] {
        guard let localization else { return [:] }
        if let su = localization["stringUnit"] as? [String: Any], let value = su["value"] as? String {
            return ["=": value]
        }
        guard let variations = localization["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (category, node) in plural {
            if let su = (node as? [String: Any])?["stringUnit"] as? [String: Any],
               let value = su["value"] as? String {
                out[category] = value
            }
        }
        return out
    }

    @Test("Every key carries an en-XA pseudolocale variant (#314)")
    func pseudolocaleCoverage() throws {
        let strings = try self.catalog()
        for (key, entry) in strings where !key.isEmpty {
            let locs = (entry as? [String: Any])?["localizations"] as? [String: Any]
            #expect(locs?["en-XA"] != nil, "Missing en-XA for key: \(key)")
        }
    }

    @Test("en-XA expands lettered copy by ~30% and keeps format specifiers (#314)")
    func pseudolocaleExpansionAndSpecifiers() throws {
        let strings = try self.catalog()
        for (key, entry) in strings where !key.isEmpty {
            guard let dict = entry as? [String: Any],
                  let locs = dict["localizations"] as? [String: Any] else { continue }
            let en = self.values(of: locs["en"] as? [String: Any])
            let xa = self.values(of: locs["en-XA"] as? [String: Any])
            for (category, xaValue) in xa {
                let enValue = en[category] ?? key
                #expect(
                    xaValue.count { $0 == "%" } == enValue.count { $0 == "%" },
                    "en-XA dropped a format specifier for \(key) [\(category)]"
                )
                guard enValue.contains(where: \.isLetter) else { continue }
                #expect(
                    Double(xaValue.count) >= Double(enValue.count) * 1.25,
                    "en-XA for \(key) [\(category)] is not ~30% longer than the English"
                )
            }
        }
    }

    @Test("Phase 3 plural keys collapse to singular forms (#314)")
    func phase3Plurals() throws {
        let strings = try self.catalog()
        let items = try #require(self.plural("%lld items", in: strings))
        #expect(items.one == "%lld item")
        let fromSelection = try #require(self.plural("From selection (%lld tracks)", in: strings))
        #expect(fromSelection.one == "From selection (%lld track)")
        let fields = try #require(self.plural("%lld fields will be updated", in: strings))
        #expect(fields.one == "%lld field will be updated")
    }

    @Test(
        "Phase 3 Playlists, MetadataEditor and Lyrics route copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Playlists/PlaylistSidebarSection.swift",
            "Sources/UI/Playlists/PlaylistRow.swift",
            "Sources/UI/Playlists/PlaylistFolderView.swift",
            "Sources/UI/Playlists/ViewModels/PlaylistSidebarViewModel.swift",
            "Sources/UI/Playlists/Smart/RuleRowView.swift",
            "Sources/UI/Playlists/Smart/RuleBuilderView.swift",
            "Sources/UI/Playlists/Smart/SmartPlaylistDetailView.swift",
            "Sources/UI/MetadataEditor/TagEditorSheet.swift",
            "Sources/UI/MetadataEditor/TagEditorSheet+DetailsTab.swift",
            "Sources/UI/MetadataEditor/TagFieldRow.swift",
            "Sources/UI/MetadataEditor/ConflictDiffSheet.swift",
            "Sources/UI/Lyrics/LyricsPane.swift",
            "Sources/UI/Lyrics/LyricsEditorSheet.swift",
            "Sources/UI/Lyrics/LyricsSettingsView.swift",
            "Sources/UI/Lyrics/LyricsView.swift",
        ]
    )
    func phase3AreasUseHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test(
        "Phase 3 Settings panes route copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Settings/GeneralSettingsView.swift",
            "Sources/UI/Settings/AppearanceSettingsView.swift",
            "Sources/UI/Settings/PlaybackSettingsView.swift",
            "Sources/UI/Settings/LibrarySettingsView.swift",
            "Sources/UI/Settings/SettingsScene.swift",
            "Sources/UI/Settings/AboutView.swift",
            "Sources/UI/Settings/SubsonicSettingsView.swift",
            "Sources/UI/Settings/SubsonicSettingsViewModel.swift",
            "Sources/UI/Settings/DiagnosticsSettingsView.swift",
            "Sources/UI/Settings/AdvancedSettingsView.swift",
            "Sources/UI/Settings/BackupSettingsViewModel.swift",
            "Sources/UI/Settings/SmartPlaylistsSettingsView.swift",
            "Sources/UI/Settings/DSPSettingsView.swift",
        ]
    )
    func phase3SettingsUsesHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test(
        "Phase 2 Browse routes copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Browse/TracksView.swift",
            "Sources/UI/Browse/TracksView+Actions.swift",
            "Sources/UI/Browse/ArtistsView.swift",
            "Sources/UI/Browse/AlbumDetailView.swift",
            "Sources/UI/Browse/QueueView.swift",
            "Sources/UI/Browse/GenresComposersView.swift",
            "Sources/UI/Browse/SmartFolders.swift",
            "Sources/UI/Browse/RemoveFromLibraryConfirm.swift",
            "Sources/UI/Browse/TrackTable+ColSpecs.swift",
            "Sources/UI/Browse/TrackTableCoordinator.swift",
            "Sources/UI/Browse/TrackTableHelpers.swift",
            "Sources/UI/Browse/Subsonic/SubsonicSongsView.swift",
            "Sources/UI/Browse/Subsonic/SubsonicAlbumsView.swift",
            "Sources/UI/Browse/Subsonic/SubsonicSongTableCells.swift",
            "Sources/UI/Browse/Subsonic/SubsonicSongTableCoordinator.swift",
            "Sources/UI/Browse/Subsonic/SubsonicOfflineBanner.swift",
        ]
    )
    func phase2BrowseUsesHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test(
        "Phase 1 chrome routes copy through the localization helper (#314)",
        arguments: [
            "Sources/UI/Common/LoadingState.swift",
            "Sources/UI/AppRoot/RootView.swift",
            "Sources/UI/AppRoot/Sidebar.swift",
            "Sources/UI/AppRoot/SubsonicSidebarSection.swift",
            "Sources/UI/AppRoot/NowPlayingStrip.swift",
            "Sources/UI/AppRoot/DiagnosticsConsentBanner.swift",
            "Sources/UI/AppRoot/CrashRecoveryBanner.swift",
            "Sources/UI/Transport/SleepTimerMenu.swift",
            "Sources/UI/MiniPlayer/MiniPlayerView.swift",
            "Sources/UI/MenuBarExtra/MenuBarExtraScene.swift",
        ]
    )
    func phase1ChromeUsesHelper(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "\(relativePath) should localize copy via L10n.string")
    }

    @Test("AlbumsGridView routes copy through the localization helper (#314)")
    func referenceScreenUsesHelper() throws {
        let url = self.moduleRoot.appendingPathComponent("Sources/UI/Browse/AlbumsGridView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("L10n.string("), "AlbumsGridView should localize copy via L10n.string")
        // The old manual singular/plural ternaries must be gone (now driven by the catalog).
        #expect(
            !source.contains("\"Play \\(ids.count) Albums\" : \"Play Album\""),
            "Manual plural ternary should be replaced by a pluralized catalog key"
        )
    }
}
