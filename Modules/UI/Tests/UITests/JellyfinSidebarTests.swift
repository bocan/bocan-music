import Foundation
import Testing
@testable import UI

@Suite("Jellyfin sidebar")
struct JellyfinSidebarTests {
    private func source(_ relative: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The source without its comment lines, so a rule that forbids a word in
    /// code is not tripped by a comment that explains the rule.
    private func code(_ relative: String) throws -> String {
        try self.source(relative)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("a Jellyfin server shows exactly the nine rows, in order, each tagged with its own server")
    func nineRows() {
        let id = UUID()
        let rows = JellyfinSidebarRows.rows(for: id)
        #expect(rows.map(\.destination) == [
            .jellyfinSongs(id), .jellyfinAlbums(id), .jellyfinArtists(id), .jellyfinGenres(id),
            .jellyfinPlaylists(id), .jellyfinStarred(id), .jellyfinRandom(id),
            .jellyfinRecentlyAdded(id), .jellyfinMostPlayed(id),
        ])
        #expect(rows.map(\.label) == [
            "Songs", "Albums", "Artists", "Genres", "Playlists", "Starred", "Random", "Recently Added", "Most Played",
        ])
    }

    @Test("the rows use the Subsonic icons")
    func icons() {
        #expect(JellyfinSidebarRows.rows(for: UUID()).map(\.symbol) == [
            "music.note", "square.grid.2x2", "music.mic", "tag", "music.note.list",
            "star", "shuffle", "clock.badge.checkmark", "chart.line.uptrend.xyaxis",
        ])
    }

    @Test("every Jellyfin destination reports its server, and no other destination does")
    func serverID() {
        let id = UUID()
        let jellyfin: [SidebarDestination] = [
            .jellyfinRoot(id), .jellyfinSongs(id), .jellyfinAlbums(id), .jellyfinArtists(id),
            .jellyfinGenres(id), .jellyfinPlaylists(id), .jellyfinStarred(id), .jellyfinRandom(id),
            .jellyfinRecentlyAdded(id), .jellyfinMostPlayed(id),
        ]
        for destination in jellyfin {
            #expect(destination.jellyfinServerID == id)
            #expect(destination.subsonicServerID == nil, "a Jellyfin row must not raise a Subsonic banner")
        }
        #expect(SidebarDestination.subsonicSongs(id).jellyfinServerID == nil)
        #expect(SidebarDestination.songs.jellyfinServerID == nil)
    }

    @Test("a Jellyfin destination survives the saved-state round trip")
    func codable() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(SidebarDestination.jellyfinAlbums(id))
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: data) == .jellyfinAlbums(id))
    }

    @Test("the kind switch picks Jellyfin for a Jellyfin server id and Subsonic for any other")
    func kindForServer() {
        let jellyfin = UUID()
        let other = UUID()
        #expect(SourcesKind.kind(forServer: jellyfin, jellyfinServerIDs: [jellyfin]) == .jellyfin)
        #expect(SourcesKind.kind(forServer: other, jellyfinServerIDs: [jellyfin]) == .subsonic)
        #expect(SourcesKind.kind(forServer: other, jellyfinServerIDs: [UUID]()) == .subsonic)
    }

    // MARK: Source conventions

    @Test("the Sidebar and the root view observe the Jellyfin model directly")
    func observation() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(sidebar.contains("@ObservedObject private var jellyfin: JellyfinSourceModel"))
        let root = try self.source("AppRoot/RootView.swift")
        #expect(root.contains("@ObservedObject private var jellyfin: JellyfinSourceModel"))
        #expect(root.contains("self.jellyfin.hasServers"), "a Jellyfin server must count as a source")
        let rows = try self.source("AppRoot/JellyfinSidebarRows.swift")
        #expect(rows.contains("@ObservedObject var model: JellyfinSourceModel"))
    }

    @Test("the Jellyfin model is not forwarded through LibraryViewModel")
    func notForwarded() throws {
        let lvm = try self.source("ViewModels/LibraryViewModel.swift")
        #expect(lvm.contains("public let jellyfin: JellyfinSourceModel"))
        #expect(!lvm.contains("jellyfin.objectWillChange"))
    }

    @Test("the empty-state button hides when only Jellyfin servers exist")
    func emptyStateHides() throws {
        let section = try self.source("AppRoot/SubsonicSidebarSection.swift")
        #expect(section.contains("if self.servers.isEmpty, !self.hasOtherServers"))
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(sidebar.contains("hasOtherServers: !self.jellyfin.servers.isEmpty"))
    }

    @Test("Hidden Sources lists hidden Jellyfin servers too")
    func hiddenSources() throws {
        let section = try self.source("AppRoot/SubsonicSidebarSection.swift")
        #expect(section.contains("self.extraHiddenMenuItems"))
        let rows = try self.source("AppRoot/JellyfinSidebarRows.swift")
        #expect(rows.contains("struct JellyfinHiddenServerMenuItems"))
    }

    @Test("Jellyfin shortcuts continue after the Subsonic ones")
    func shortcutsContinue() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(sidebar.contains("firstShortcutIndex: self.vm.subsonicServers.count"))
    }

    @Test("the Sources page keeps the kind in @State, never in @AppStorage")
    func kindIsState() throws {
        let scene = try self.source("Settings/SettingsScene.swift")
        #expect(scene.contains("@State private var sourcesKind: SourcesKind"))
        let page = try self.code("Settings/SourcesSettingsPage.swift")
        #expect(!page.contains("@AppStorage"))
    }

    @Test("no Jellyfin source file puts a UserDefaults mirror in a didSet")
    func noUnguardedMirror() throws {
        let files = [
            "AppRoot/JellyfinSourceModel.swift",
            "AppRoot/JellyfinSidebarRows.swift",
            "Settings/JellyfinSettingsViewModel.swift",
        ]
        for file in files {
            let text = try self.code(file)
            #expect(!text.contains("UserDefaults"), "\(file) must not mirror state into UserDefaults")
            #expect(!text.contains("didSet"))
        }
    }

    @Test("every Jellyfin control carries help text")
    func helpText() throws {
        let text = try self.source("Settings/JellyfinServerEditorView.swift")
        let controls = text.components(separatedBy: "Toggle(").count - 1
            + text.components(separatedBy: "Picker(").count - 1
        let helps = text.components(separatedBy: ".help(").count - 1
        #expect(helps >= controls, "a Toggle or Picker has no .help()")
    }
}
