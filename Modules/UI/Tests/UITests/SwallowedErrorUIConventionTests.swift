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
