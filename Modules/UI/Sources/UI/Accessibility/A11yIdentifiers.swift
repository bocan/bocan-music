import Foundation

// swiftlint:disable missing_docs

/// Accessibility identifier constants for Bòcan's UI.
///
/// Using nested enums avoids typo-prone string literals and keeps
/// selectors co-located by feature for easy UI-test authoring.
public enum A11y {
    // MARK: - Sidebar

    public enum Sidebar {
        public static let sidebar = "sidebar"
        public static let list = "sidebar.list"
        public static let songs = "sidebar.songs"
        public static let albums = "sidebar.albums"
        public static let artists = "sidebar.artists"
        public static let genres = "sidebar.genres"
        public static let composers = "sidebar.composers"
        public static let recentlyAdded = "sidebar.recentlyAdded"
        public static let recentlyPlayed = "sidebar.recentlyPlayed"
        public static let mostPlayed = "sidebar.mostPlayed"
    }

    // MARK: - Tracks table

    public enum TracksTable {
        public static let table = "tracksTable"
        public static let emptyState = "tracksTable.emptyState"
    }

    // MARK: - Albums grid

    public enum AlbumsGrid {
        public static let grid = "albumsGrid"
        public static let emptyState = "albumsGrid.emptyState"
    }

    // MARK: - Now-playing strip

    public enum NowPlaying {
        public static let strip = "nowPlayingStrip"
        public static let artwork = "nowPlayingStrip.artwork"
        public static let title = "nowPlayingStrip.title"
        public static let artist = "nowPlayingStrip.artist"
        public static let playPause = "nowPlayingStrip.playPause"
        public static let playPauseButton = "nowPlayingStrip.playPause"
        public static let prev = "nowPlayingStrip.prev"
        public static let prevButton = "nowPlayingStrip.prev"
        public static let next = "nowPlayingStrip.next"
        public static let nextButton = "nowPlayingStrip.next"
        public static let scrubber = "nowPlayingStrip.scrubber"
        public static let volume = "nowPlayingStrip.volume"
        public static let volumeSlider = "nowPlayingStrip.volume"
    }

    // MARK: - Search

    public enum Search {
        public static let field = "searchField"
        public static let results = "searchResults"
    }

    // MARK: - Playlists

    public enum PlaylistSidebar {
        public static let section = "playlist.sidebar.section"
        public static let addButton = "playlist.sidebar.add"
        public static let newNameField = "playlist.sidebar.newName"

        public static func row(_ id: Int64) -> String {
            "playlist.sidebar.row.\(id)"
        }

        public static func folderRow(_ id: Int64) -> String {
            "playlist.sidebar.folderRow.\(id)"
        }
    }

    public enum PlaylistDetail {
        public static let view = "playlist.detail.view"
        public static let header = "playlist.detail.header"
        public static let list = "playlist.detail.list"
        public static let playButton = "playlist.detail.play"
        public static let shuffleButton = "playlist.detail.shuffle"
    }

    public enum SmartPlaylistDetail {
        public static let view = "smartPlaylist.detail.view"
        public static let header = "smartPlaylist.detail.header"
        public static let editButton = "smartPlaylist.detail.edit"
    }

    public enum RuleBuilder {
        public static let view = "ruleBuilder.view"
        public static let saveButton = "ruleBuilder.save"
        public static let addRuleButton = "ruleBuilder.addRule"
    }

    // MARK: - Search field (alias kept for symmetry)

    public enum SearchField {
        public static let field = "searchField"
        public static let results = "searchResults"
    }

    // MARK: - Search results

    public enum SearchResults {
        public static let results = "searchResults"
    }
}

/// Legacy flat alias — retained so any UITest code written before the
/// nested structure works without modification.
public typealias A11yIdentifiers = A11y

// swiftlint:enable missing_docs
