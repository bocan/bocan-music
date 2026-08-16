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
        public static let upNext = "sidebar.upNext"
        public static let radio = "sidebar.radio"
        public static let podcasts = "sidebar.podcasts"
        public static let addFolderButton = "sidebar.addFolder"
    }

    /// Radio station catalog (ADR-078).
    public enum Radio {
        public static let list = "radio.list"
        public static let emptyState = "radio.emptyState"
        public static let addButton = "radio.addStation"
        public static let emptyStateAddButton = "radio.emptyState.addStation"

        /// One row per station; nil ids (unsaved rows) collapse to a stable
        /// placeholder so the identifier is never empty.
        public static func row(_ stationID: Int64?) -> String {
            "radio.row.\(stationID.map(String.init) ?? "unsaved")"
        }

        // MARK: - Add/edit sheet (ADR-085)

        public static let sheetNameField = "radio.sheet.name"
        public static let sheetStreamURLField = "radio.sheet.streamURL"
        public static let sheetHomePageField = "radio.sheet.homePage"
        public static let sheetSubmitButton = "radio.sheet.submit"
        public static let sheetCancelButton = "radio.sheet.cancel"
        public static let sheetFoundList = "radio.sheet.foundList"
        public static let sheetAddAllButton = "radio.sheet.addAll"

        public static func sheetFoundRow(_ index: Int) -> String {
            "radio.sheet.foundRow.\(index)"
        }

        // MARK: - Info sheet (ADR-085)

        /// One row's value text, keyed by a stable slug (not the localized
        /// label, which must stay free to translate): "container", "codec",
        /// "sampleRate", "channels", "bitrate", "nowPlayingTitles",
        /// "lastConnected".
        public static func infoValue(_ key: String) -> String {
            "radio.info.value.\(key)"
        }

        public static let infoCloseButton = "radio.info.close"
    }

    // MARK: - Tracks table

    public enum TracksTable {
        public static let table = "tracksTable"
        public static let emptyState = "tracksTable.emptyState"
        /// The Subsonic browse song table (a second AppKit `NSTableView`).
        public static let subsonicTable = "subsonicSongsTable"
    }

    // MARK: - Albums grid

    public enum AlbumsGrid {
        public static let grid = "albumsGrid"
        public static let emptyState = "albumsGrid.emptyState"

        /// One tile per album; nil ids (unsaved rows) collapse to a stable
        /// placeholder so the identifier is never empty.
        public static func tile(_ albumID: Int64?) -> String {
            "albumsGrid.tile.\(albumID.map(String.init) ?? "unsaved")"
        }
    }

    // MARK: - Main-window toolbar

    public enum Toolbar {
        public static let back = "toolbar.back"
        public static let forward = "toolbar.forward"
        public static let miniPlayerToggle = "toolbar.miniPlayer"
        public static let lyricsToggle = "toolbar.lyrics"
        public static let visualizerToggle = "toolbar.visualizer"
        public static let identifyTrack = "toolbar.identifyTrack"
    }

    // MARK: - Shared components

    public enum EmptyStateIDs {
        /// The call-to-action button; at most one empty state is visible per
        /// screen context, so a uniform identifier stays unambiguous.
        public static let actionButton = "emptyState.action"
    }

    public enum ScanBanner {
        public static let dismissButton = "scanBanner.dismiss"
    }

    // MARK: - Podcasts browse

    public enum Podcasts {
        public static let addBarField = "podcasts.addBar.field"
        public static let addBarClearButton = "podcasts.addBar.clear"

        // MARK: - Subscribe by URL (ADR-085)

        /// The search results row offering to add the pasted feed URL.
        public static let addByURLRow = "podcasts.addByURLRow"
        /// The Subscribe button on the feed detail sheet.
        public static let detailSubscribeButton = "podcasts.detail.subscribe"
        /// The show page's "More" toolbar menu (Refresh, Unsubscribe, ...).
        public static let showMoreMenu = "podcasts.show.moreMenu"
    }

    // MARK: - Mini player chrome

    public enum MiniPlayer {
        public static let layoutButton = "miniPlayer.layout"
        public static let pinButton = "miniPlayer.pin"
        public static let dismissButton = "miniPlayer.dismiss"
    }

    // MARK: - Log console window

    public enum LogConsole {
        public static let levelPicker = "logConsole.level"
        public static let categoriesMenu = "logConsole.categories"
        public static let searchField = "logConsole.search"
        public static let pauseButton = "logConsole.pause"
        public static let clearMenu = "logConsole.clear"
        public static let copyButton = "logConsole.copy"
        public static let exportButton = "logConsole.export"
        public static let tailToggle = "logConsole.tail"
    }

    // MARK: - Equaliser & DSP window

    public enum DSPWindow {
        public static let eqEnableToggle = "dsp.eq.enable"
        public static let eqOutputGain = "dsp.eq.outputGain"
        public static let eqPresetMenu = "dsp.eq.preset"
        public static let eqScopePicker = "dsp.eq.scope"

        /// One vertical slider per EQ band, keyed by its frequency label
        /// ("32", "1k", "16k", ...).
        public static func eqBand(_ label: String) -> String {
            "dsp.eq.band.\(label)"
        }
    }

    // MARK: - Settings panes

    public enum SettingsIDs {
        /// Sidebar navigation rows, keyed by `SettingsPage.rawValue`. Tag-
        /// selected `List(selection:)` rows are otherwise absent from the AX
        /// tree (the same VoiceOver defect the main sidebar hit in ADR-081).
        public static func sidebarRow(_ pageRawValue: String) -> String {
            "settings.sidebar.\(pageRawValue)"
        }

        /// Appearance accent swatches, keyed by palette id ("blue", ...).
        public static func accentSwatch(_ id: String) -> String {
            "settings.appearance.accent.\(id)"
        }

        // Form toggles (each pane's switches, in sidebar order)
        public static let launchAtLogin = "settings.general.launchAtLogin"
        public static let restoreWindowMode = "settings.general.restoreWindowMode"
        public static let menuBarExtra = "settings.general.menuBarExtra"
        public static let dockAlbumArt = "settings.general.dockAlbumArt"
        public static let dockBadge = "settings.general.dockBadge"
        public static let dockProgress = "settings.general.dockProgress"
        public static let trackNotifications = "settings.general.notifications"
        public static let watchFolders = "settings.library.watchFolders"
        public static let quickScan = "settings.library.quickScan"
        public static let embedCoverArt = "settings.library.embedCoverArt"
        public static let crossAlbumGapless = "settings.playback.crossAlbumGapless"
        public static let sleepFadeOut = "settings.playback.sleepFadeOut"
        public static let podcastRefreshOnLaunch = "settings.podcasts.refreshOnLaunch"
        public static let smartLiveUpdate = "settings.smartPlaylists.liveUpdate"
        public static let smartRandomReroll = "settings.smartPlaylists.randomReroll"
        public static let lyricsAutoShow = "settings.lyrics.autoShowPane"
        public static let lyricsLrclib = "settings.lyrics.lrclib"
        public static let lyricsEmbedOnSave = "settings.lyrics.embedOnSave"
        public static let vizSimplifyOnBattery = "settings.visualizer.simplifyOnBattery"

        // Advanced
        public static let icloudBackupToggle = "settings.advanced.backup.icloud.toggle"
        public static let icloudBackupNow = "settings.advanced.backup.icloud.now"
        public static let localBackupToggle = "settings.advanced.backup.local.toggle"
        public static let localBackupNow = "settings.advanced.backup.local.now"
        public static let showBackupsInFinder = "settings.advanced.backup.local.showInFinder"
        public static let logLevelPicker = "settings.advanced.logLevel"
        public static let revealDatabase = "settings.advanced.revealDatabase"
        public static let rebuildFTS = "settings.advanced.rebuildFTS"
        public static let resetPreferences = "settings.advanced.resetPreferences"
        public static let exportDiagnostics = "settings.advanced.exportDiagnostics"

        // Diagnostics (report-row controls are uniform; the row's label
        // carries the file name, per the row-disambiguation convention)
        public static let reportCopyPath = "settings.diagnostics.report.copyPath"
        public static let reportView = "settings.diagnostics.report.view"
        public static let openReportsFolder = "settings.diagnostics.openReportsFolder"
        public static let openLogConsole = "settings.diagnostics.openLogConsole"

        // Diagnostics toggles
        public static let crashConsentToggle = "settings.diagnostics.crashConsent"
        public static let captureLogsToggle = "settings.diagnostics.captureLogs"

        // Podcasts
        public static let podcastDefaultSpeed = "settings.podcasts.defaultSpeed"
        public static let podcastRefreshInterval = "settings.podcasts.refreshInterval"
        public static let podcastAutoDownload = "settings.podcasts.autoDownload"
        public static let podcastSkipBack = "settings.podcasts.skipBack"
        public static let podcastSkipForward = "settings.podcasts.skipForward"
        public static let podcastStorefront = "settings.podcasts.storefront"

        // Visualizer
        public static let vizSensitivityReset = "settings.visualizer.sensitivityReset"
        public static let vizMode = "settings.visualizer.mode"
        public static let vizPalette = "settings.visualizer.palette"
        public static let vizFrameRate = "settings.visualizer.frameRate"

        // Effects
        public static let bassBoost = "settings.effects.bassBoost"
        public static let crossfade = "settings.effects.crossfade"
        public static let crossfeed = "settings.effects.crossfeed"
        public static let stereoWidth = "settings.effects.stereoWidth"

        // Library
        public static let addFiles = "settings.library.addFiles"
        public static let addFolder = "settings.library.addFolder"
        public static let removeRoot = "settings.library.removeRoot"

        // Phone Sync
        public static let phoneSyncToggle = "settings.phoneSync.enable"
        public static let pairPhone = "settings.phoneSync.pair"
        public static let phoneSyncMode = "settings.phoneSync.mode"
        public static let phoneSyncIncludePodcasts = "settings.phoneSync.includePodcasts"
        /// Uniform across the playlist checkboxes; the row's label (the
        /// playlist name) disambiguates.
        public static let phoneSyncPlaylistToggle = "settings.phoneSync.playlistToggle"

        // Playback
        public static let speedSlider = "settings.playback.speed"
        public static let speedReset = "settings.playback.speedReset"
        public static let prerollSlider = "settings.playback.preroll"

        // ReplayGain
        public static let rgComputeMissing = "settings.replayGain.computeMissing"
        public static let rgRecomputeAll = "settings.replayGain.recomputeAll"
        public static let rgPreamp = "settings.replayGain.preamp"

        // Scrobbling
        public static let scrobbleDisconnect = "settings.scrobble.disconnect"
        public static let recentScrobbles = "settings.scrobble.recent"

        // Sources
        public static let addServer = "settings.sources.addServer"
        public static let addServerEmpty = "settings.sources.addServer.empty"

        /// Visualizer
        public static let vizSensitivity = "settings.visualizer.sensitivity"
    }

    // MARK: - Library Summary window

    public enum LibrarySummary {
        /// One tab-strip button per section, keyed by the tab's raw value
        /// ("basicInfo", "audioQuality", ...).
        public static func tab(_ rawValue: String) -> String {
            "librarySummary.tab.\(rawValue)"
        }
    }

    // MARK: - Now-playing strip

    public enum NowPlaying {
        public static let strip = "nowPlayingStrip"
        public static let artwork = "nowPlayingStrip.artwork"
        public static let playPause = "nowPlayingStrip.playPause"
        public static let prev = "nowPlayingStrip.prev"
        public static let next = "nowPlayingStrip.next"
        public static let scrubber = "nowPlayingStrip.scrubber"
        /// The CUE marker line under the title/artist (ADR-087); present only
        /// while playing inside a marker of a multi-marker track.
        public static let markerLine = "nowPlayingStrip.markerLine"
        public static let volume = "nowPlayingStrip.volume"
        public static let volumeSlider = "nowPlayingStrip.volume"
        public static let muteButton = "nowPlayingStrip.mute"
        public static let artworkButton = "nowPlayingStrip.artwork.button"
        public static let titleButton = "nowPlayingStrip.title.button"
        public static let subtitleButton = "nowPlayingStrip.subtitle.button"
        public static let infoButton = "nowPlayingStrip.info"
        public static let loveButton = "nowPlayingStrip.love"
        public static let shuffleButton = "nowPlayingStrip.shuffle"
        public static let repeatButton = "nowPlayingStrip.repeat"
        public static let stopAfterCurrentButton = "nowPlayingStrip.stopAfterCurrent"
        public static let speedPicker = "nowPlayingStrip.speedPicker"
        public static let sleepTimer = "nowPlayingStrip.sleepTimer"
        public static let dspButton = "nowPlayingStrip.dsp"
        public static let visualizerButton = "nowPlayingStrip.visualizer"
        public static let scrobblePendingButton = "nowPlayingStrip.scrobblePending"
        public static let skipBack = "nowPlayingStrip.skipBack"
        public static let skipForward = "nowPlayingStrip.skipForward"
    }

    // MARK: - Search

    public enum Search {
        public static let field = "searchField"
        public static let results = "searchResults"
    }

    // MARK: - Sources

    public enum SourcesSidebar {
        public static let addButton = "sources.sidebar.add"
        public static let emptyStateAddButton = "sources.sidebar.emptyAdd"
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

    public enum PlaylistFolderDetail {
        public static let view = "playlistFolder.detail.view"
        public static let header = "playlistFolder.detail.header"

        public static func childRow(_ id: Int64) -> String {
            "playlistFolder.detail.child.\(id)"
        }
    }

    public enum SmartPlaylistDetail {
        public static let view = "smartPlaylist.detail.view"
        public static let header = "smartPlaylist.detail.header"
        public static let editButton = "smartPlaylist.detail.edit"
        public static let refreshButton = "smartPlaylist.detail.refresh"
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

    // MARK: - Visualizer

    public enum Visualizer {
        public static let pane = "visualizerPane"
        public static let closeButton = "visualizerPane.close"
        public static let host = "visualizerPane.host"
        /// Shared across the pane, mini player, and fullscreen overlays — only
        /// one is ever on screen frontmost at a time in the E2E crawl.
        public static let modeStepper = "visualizer.overlay.mode"
        public static let paletteStepper = "visualizer.overlay.palette"
        /// Plain, non-adjustable siblings of the steppers above, exposing the
        /// current mode/palette name as their `.accessibilityValue`: the
        /// stepper rows' own `.accessibilityAdjustableAction` role does not
        /// reliably bridge a value to XCUITest, even though its label does
        /// (ADR-084, found empirically).
        public static let modeValue = "visualizer.overlay.mode.value"
        public static let paletteValue = "visualizer.overlay.palette.value"
    }

    // MARK: - Playlist import sheet (ADR-085)

    public enum PlaylistImport {
        public static let chooseFilesButton = "playlistImport.chooseFiles"
        public static let cancelButton = "playlistImport.cancel"
        public static let importButton = "playlistImport.import"
    }

    // MARK: - Lyrics

    public enum Lyrics {
        public static let pane = "lyricsPane"
        public static let closeButton = "lyricsPane.close"
        public static let emptyState = "lyricsPane.emptyState"
        public static let fetchButton = "lyricsPane.fetchButton"
        public static let replaceButton = "lyricsPane.replaceButton"
        public static let offsetButton = "lyricsPane.offsetButton"
        public static let offsetSlider = "lyricsPane.offsetSlider"
        public static let unsyncedScroll = "lyricsPane.unsyncedScroll"
        public static let syncedScroll = "lyricsPane.syncedScroll"
        public static let editor = "lyricsEditor"
        public static let insertTimestampButton = "lyricsEditor.insertTimestamp"
    }
}

/// Legacy flat alias — retained so any UITest code written before the
/// nested structure works without modification.
public typealias A11yIdentifiers = A11y

// swiftlint:enable missing_docs
