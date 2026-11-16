import Foundation
import Testing
@testable import UI

/// Structural rules for `Browse/Jellyfin/` that the compiler cannot check (ADR-097).
@Suite("Jellyfin browse conventions")
struct JellyfinBrowseConventionTests {
    private var sourceRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func browseFiles() throws -> [(name: String, text: String)] {
        let folder = self.sourceRoot.appendingPathComponent("Browse/Jellyfin")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map { name in
            try (name, String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))
        }
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: self.sourceRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the folder holds the browse files and no Jellyfin file imports Subsonic or SwiftSonic")
    func mirrorsWithoutImporting() throws {
        let files = try self.browseFiles()
        #expect(files.count >= 15)
        for file in files {
            #expect(!file.text.contains("import Subsonic"), "\(file.name) imports Subsonic")
            #expect(!file.text.contains("import SwiftSonic"), "\(file.name) imports SwiftSonic")
            #expect(!file.text.contains("import JellyfinAPI"), "\(file.name) imports the SDK, which only the Jellyfin module may")
        }
    }

    @Test("every Settings control for Jellyfin carries its identifier, the Sources switch included (ADR-097 slice 7)")
    func settingsIdentifiersAreUsed() throws {
        let files = [
            "Settings/SourcesSettingsPage.swift",
            "Settings/JellyfinSettingsView.swift",
            "Settings/JellyfinServerEditorView.swift",
        ]
        let settings = try files.map { try self.source($0) }.joined(separator: "\n")
        let ids = try self.source("Accessibility/A11yIdentifiers+Jellyfin.swift")
        // Only the Settings enum: the browse enum above it is used elsewhere.
        let settingsBlock = try #require(ids.components(separatedBy: "enum JellyfinSettings").last)
        let settingsNames = settingsBlock.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "public static let ") else { return nil }
            return line[range.upperBound...].split(separator: " ").first.map(String.init)
        }
        #expect(settingsNames.count >= 20)
        for name in settingsNames {
            #expect(settings.contains("A11y.JellyfinSettings.\(name))"), "A11y.JellyfinSettings.\(name) is never applied")
        }
    }

    @Test("the server row and its nine rows carry identifiers, which the E2E journey clicks (ADR-097 slice 9)")
    func sidebarRowsAreIdentified() throws {
        let keys = JellyfinSidebarRows.rows(for: UUID()).map(\.key)
        #expect(keys.count == 9)
        #expect(Set(keys).count == keys.count)
        let rows = try self.source("AppRoot/JellyfinSidebarRows.swift")
        #expect(rows.contains(".accessibilityIdentifier(A11y.Jellyfin.sidebarRow(row.key))"))
        #expect(rows.contains(".accessibilityIdentifier(A11y.Jellyfin.sidebarServer)"))
    }

    @Test("no Jellyfin browse file swallows an error with try?")
    func noSwallowedErrors() throws {
        for file in try self.browseFiles() {
            let code = file.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!code.contains { $0.contains("try?") }, "\(file.name) uses try?")
        }
    }

    @Test("no Jellyfin browse file logs or stores a URL, which carries the access token")
    func noURLLogging() throws {
        for file in try self.browseFiles() {
            let code = file.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let logLines = code.filter { $0.contains("log.") }
            #expect(!logLines.contains { $0.localizedCaseInsensitiveContains("url") }, "\(file.name) logs a URL")
        }
    }

    @Test("every Jellyfin destination is routed to a view by JellyfinDestinationView")
    func everyDestinationRouted() throws {
        let router = try self.source("Browse/Jellyfin/JellyfinDestinationView.swift")
        for name in [
            "jellyfinRoot", "jellyfinSongs", "jellyfinAlbums", "jellyfinArtists", "jellyfinGenres", "jellyfinPlaylists",
            "jellyfinStarred", "jellyfinRandom", "jellyfinRecentlyAdded", "jellyfinMostPlayed",
            "jellyfinPlaylist(", "jellyfinArtist(", "jellyfinAlbum(",
        ] {
            #expect(router.contains(".\(name)"), "\(name) is not routed")
        }
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(pane.contains("JellyfinDestinationView(destination:"))
        #expect(pane.contains("JellyfinOfflineBannerHost(model: self.vm.jellyfin"))
    }

    @Test("the Jellyfin song table keeps the Subsonic table's performance rules")
    func tableKeepsThePerformanceRules() throws {
        let table = try self.source("Browse/Jellyfin/JellyfinSongTable.swift")
        #expect(table.contains("rowsVersion"), "version-gated updates (#455)")
        #expect(table.contains("changedRowIDs"), "in-place row reloads (#476)")
        #expect(table.contains("autosaveTableColumns"), "saved column order and widths (#369)")
        #expect(table.contains("applyPreservingSelection"), "a reload keeps the selection")
        let model = try self.source("Browse/Jellyfin/JellyfinSongListModel.swift")
        #expect(model.contains("rowsVersion &+= 1"), "the version moves in a didSet, so no path can forget it")
    }

    @Test("a Jellyfin view that reads the model through the library observes it directly")
    func observesTheModelDirectly() throws {
        let support = try self.source("Browse/Jellyfin/JellyfinBrowseSupport.swift")
        #expect(support.contains("@ObservedObject var jellyfin: JellyfinSourceModel"))
        #expect(support.contains("@ObservedObject var model: JellyfinSourceModel"))
    }

    @Test("Jellyfin songs play as .jellyfin queue items, never as Subsonic ones")
    func playbackBuildsJellyfinItems() throws {
        let text = try self.source("ViewModels/LibraryViewModel+Jellyfin.swift")
        #expect(text.contains("playableSource: .jellyfin(serverID: payload.serverID, itemID: payload.songID)"))
        #expect(!text.contains(".subsonic("))
        #expect(!text.contains("not ready yet"))
    }

    @Test("the Up Next queue accepts Jellyfin drops, and Subsonic drops still reach their own target")
    func queueAcceptsJellyfinDrops() throws {
        let queue = try self.source("Browse/QueueView.swift")
        #expect(queue.contains("SubsonicSongDropTarget"))
        #expect(queue.contains("JellyfinSongDropTarget"))
        #expect(queue.contains("addJellyfinSongsToQueue"))
        // The Jellyfin overlay is on top, so it must step aside for any other drag.
        let drag = try self.source("Browse/Jellyfin/JellyfinSongDrag.swift")
        #expect(drag.contains("JellyfinSongDrag.dragInProgressCarriesSongs else { return nil }"))
    }

    @Test("every Jellyfin song table follows the playing song")
    func tablesFollowThePlayingSong() throws {
        let support = try self.source("Browse/Jellyfin/JellyfinBrowseSupport.swift")
        let songs = try self.source("Browse/Jellyfin/JellyfinSongsView.swift")
        #expect(support.contains("nowPlayingRowID: self.library.nowPlaying.jellyfinRowID"))
        #expect(songs.contains("nowPlayingRowID: self.library.nowPlaying.jellyfinRowID"))
        #expect(!support.contains("nowPlayingRowID: nil"))
        #expect(!songs.contains("nowPlayingRowID: nil"))
    }
}
