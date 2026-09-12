import Foundation
import Testing
@testable import UI

// MARK: - SwallowedErrorUIConventionTests

/// #480: the `try?` audit found nine places in this module where a user
/// action failed and said nothing (`docs/audits/try-optional-audit.md`, class
/// (c)). Menus, file pickers, drops, alerts and the composition root cannot be
/// driven host-less, so these pin the fixed shapes in the source: the error is
/// caught, logged, and put where the person who pressed the button will see it.
@Suite("Swallowed-error conventions in UI (#480)")
struct SwallowedErrorUIConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Add to Playlist reports a failure as a toast")
    func addToPlaylistReportsFailure() throws {
        let source = try self.source("Sources/UI/Browse/TracksView+Actions.swift")
        #expect(!source.contains("try? await lib.playlistService.addTracks"))
        #expect(source.contains("lib.log.error(\"playlist.addTracks.failed\""))
        #expect(source.contains("L10n.string(\"Couldn’t add those tracks to the playlist.\")"))
    }

    @Test("the Love toggle reports a failed read as a toast")
    func loveReportsFailure() throws {
        let source = try self.source("Sources/UI/ViewModels/LibraryViewModel+Rating.swift")
        #expect(!source.contains("try? await repo.fetch(id: trackID)"))
        #expect(source.contains("self.log.error(\"love.fetch.failed\""))
        #expect(source.contains("L10n.string(\"Couldn’t update Loved for that track.\")"))
    }

    @Test("Save Log shows why a write failed")
    func saveLogReportsFailure() throws {
        let source = try self.source("Sources/UI/Console/LogConsoleView.swift")
        #expect(!source.contains("try? text.write("))
        #expect(source.contains("AppLogger.make(.ui).error(\"log.export.failed\""))
        #expect(source.contains("self.exportError = error.localizedDescription"))
        #expect(source.contains(".alert(L10n.string(\"Couldn’t save the log\")"))
    }

    @Test("an unreadable image the user picked or dropped reaches the editor's error alert")
    func artworkReportsFailure() throws {
        let source = try self.source("Sources/UI/MetadataEditor/ArtworkEditor.swift")
        #expect(!source.contains("try? Data(contentsOf:"))
        #expect(source.contains("AppLogger.make(.ui).error(\"artwork.read.failed\""))
        #expect(source.contains("AppLogger.make(.ui).error(\"artwork.drop.failed\""))
        #expect(source.contains("self.vm.lastError = L10n.string(\"Couldn’t read that image file.\")"))
    }

    @Test("every scrobbler Disconnect reports a Keychain failure in its own field")
    func disconnectReportsFailure() throws {
        let source = try self.source("Sources/UI/Scrobble/ScrobbleSettingsViewModel.swift")
        #expect(!source.contains("try? await self.credentials.clear"))
        let events = [
            "scrobble.lastfm.disconnect.failed",
            "scrobble.listenbrainz.disconnect.failed",
            "scrobble.rocksky.disconnect.failed",
        ]
        for event in events {
            #expect(source.contains(event), "missing \(event)")
        }
        #expect(source.contains("self.lastFmAuthError = self.message(for: error)"))
        #expect(source.contains("self.listenBrainzTokenError = self.message(for: error)"))
        #expect(source.contains("self.rockskyConnectError = self.message(for: error)"))
    }

    @Test("a tag-editor service that cannot start says so in the log")
    func metadataEditServiceInitLogs() throws {
        let source = try self.source("Sources/UI/ViewModels/LibraryViewModel.swift")
        #expect(!source.contains("try? MetadataEditService("))
        #expect(source.contains("self.metadataEditService = try MetadataEditService(database: database)"))
        #expect(source.contains("AppLogger.make(.ui).error(\"metadataEditService.init_failed\""))
    }
}

// MARK: - QuietRecoveryUIConventionTests

/// #491: the audit found 57 places in this module that recovered from a failed
/// read correctly but silently (`docs/audits/try-optional-audit.md`, class
/// (b)). Every recovery and every fallback value is unchanged. What needed
/// pinning is the log line that now explains each one, and a log cannot be read
/// back from a host-less test.
@Suite("Quiet-recovery conventions in UI (#491)")
struct QuietRecoveryUIConventionTests {
    private var sourceRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The wrapper only supplies this module's logging category. That it logs
    /// the error and returns nil is `Observability.logged`'s job, and is
    /// covered directly by `LoggedTests` over there (#459).
    @Test("the module's helper delegates to the shared recover-and-log helper")
    func recoveredReadDelegates() throws {
        let source = try self.source("Common/RecoveredRead.swift")
        #expect(source.contains("func recoveredRead<T: Sendable>"))
        #expect(source.contains("await logged(event, AppLogger.make(.ui), fetch)"))
    }

    /// These files had every one of their swallowed reads replaced, so the
    /// absence of `try?` is itself the assertion.
    @Test("a page that loads empty now says whether the read failed")
    func emptyPagesSayWhy() throws {
        let cases = [
            ("Browse/GenresView.swift", "genres.allGenres.failed"),
            ("Browse/ComposersView.swift", "composers.allComposers.failed"),
            ("Browse/ArtistsView.swift", "artistDetail.albums.failed"),
            ("Browse/AlbumsGridView.swift", "albumsGrid.openInspector.failed"),
            ("DeepDive/ArtistInfoSheet.swift", "artistInfo.artist.failed"),
            ("ViewModels/AlbumsViewModel.swift", "albums.artistNames.failed"),
            ("ViewModels/ArtistsViewModel.swift", "artists.albumCounts.failed"),
            ("ViewModels/TracksViewModel.swift", "tracks.artistNames.failed"),
            ("ViewModels/LibraryViewModel+Navigation.swift", "library.smartFolder.failed"),
            ("MetadataEditor/ViewModels/TagEditorViewModel.swift", "tagEditor.readTags.failed"),
            ("Browse/Podcasts/PodcastsViewModel+Counts.swift", "podcasts.episodeCounts.failed"),
            ("Common/NoticesHTMLView.swift", "notices.read.failed"),
            ("Settings/GeneralSettingsView.swift", "notifications.authRequest.failed"),
        ]
        for (path, event) in cases {
            let source = try self.source(path)
            #expect(source.contains(event), "missing \(event)")
            #expect(!source.contains("try?"), "\(path) still swallows a read error")
        }
    }

    /// A comment-only `catch` is the same defect as a `try?` and no text search
    /// for `try?` can see it. These three were found by reading the catches in
    /// this module rather than by the audit (#498 taught the lesson, #491
    /// applied it). The fourth, in `PodcastsHomeView`, is left alone: its only
    /// possible error is the debounce cancelling, which is the working case.
    @Test("a catch that only carried a comment now carries a log line")
    func commentOnlyCatchesLog() throws {
        let cases = [
            ("Browse/AlbumDetailView.swift", "albumDetail.load.failed"),
            ("Playlists/Smart/SmartPresetPickerView.swift", "smartPresets.list.failed"),
            ("Browse/Podcasts/PodcastsGridView.swift", "podcasts.refresh.failed"),
        ]
        for (path, event) in cases {
            let source = try self.source(path)
            #expect(source.contains(event), "missing \(event)")
        }
    }

    /// This module's allowlist is not a single idiom, as Playback's and
    /// Scrobble's are, so it is spelled out. Anything else swallowing an error
    /// is a regression.
    @Test("every remaining try? in this module is an allowlisted idiom")
    func onlyAllowlistedIdiomsSwallow() throws {
        let allowed = [
            "Task.sleep",
            "JSONDecoder", "JSONEncoder", "JSONSerialization",
            "removeItem", "createDirectory", "copyItem",
            "String(contentsOf:",
            "self.service.ping(",
            "provider.coverArtURL(",
            "URLSession.shared.data(",
            "UNNotificationAttachment(",
        ]
        let enumerator = try #require(
            FileManager.default.enumerator(at: self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("try?"), !trimmed.hasPrefix("//") else { continue }
                if !allowed.contains(where: trimmed.contains) {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "a swallowed error outside the allowlist: \(offenders)")
    }
}
