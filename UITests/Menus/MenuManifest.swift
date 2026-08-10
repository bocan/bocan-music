import Foundation

// MARK: - MenuItemSpec

/// One expected menu item (phase 30). `titles` lists every label the item
/// can carry (dynamic Show/Hide and Mute/Unmute pairs); the first is
/// canonical. Shortcuts are declared as display strings ("⇧⌘N") and
/// parsed into `MenuShortcut` for comparison, so the manifest reads like
/// the help book's table.
struct MenuItemSpec {
    let titles: [String]
    /// Expected shortcut; the parity test checks it against the source
    /// declaration and `KeyBindings.swift`.
    var shortcut: MenuShortcut?
    /// `KeyBindings` constant name the source must route through (nil for
    /// inline shortcuts and shortcut-less items).
    var binding: String?
    /// Action name of this item's row in the help book's Keyboard
    /// Shortcuts table, where it has one.
    var helpBookRow: String?
    /// Apple- or SwiftUI-owned: structure is asserted, but enablement and
    /// invocation passes leave it alone.
    var system = false
    /// Non-nil when the item can legitimately be absent; the value is the
    /// reason (feature flag, build configuration).
    var conditional: String?
    /// Skip child comparison (Services, AutoFill: machine-specific).
    var ignoreChildren = false
    var submenu: [MenuItemSpec] = []

    var canonicalTitle: String {
        self.titles[0]
    }

    /// An app-owned item.
    static func own(
        _ titles: String...,
        key: String? = nil,
        binding: String? = nil,
        row: String? = nil,
        conditional: String? = nil,
        submenu: [MenuItemSpec] = []
    ) -> MenuItemSpec {
        MenuItemSpec(
            titles: titles,
            shortcut: key.map { MenuShortcut.fromDisplay($0)! },
            binding: binding,
            helpBookRow: row,
            conditional: conditional,
            submenu: submenu
        )
    }

    /// An Apple- or SwiftUI-owned item the app cannot remove.
    static func sys(_ titles: String..., ignoreChildren: Bool = false) -> MenuItemSpec {
        MenuItemSpec(titles: titles, system: true, ignoreChildren: ignoreChildren)
    }
}

// MARK: - MenuSpec

/// One expected top-level menu.
struct MenuSpec {
    let title: String
    /// `false` for menus whose contents are wholly system-managed and
    /// machine-dependent (Window: tiling, tab items, open-window list).
    var crawlContents = true
    var items: [MenuItemSpec] = []
}

// MARK: - MenuManifest

/// The declarative single source of truth for the phase 30 crawl: every
/// top-level menu in order, every item in order, with expected titles,
/// shortcuts, help book rows, and ownership. The structural crawl fails
/// bidirectionally on any drift between this table and the live menu bar;
/// the parity test fails on drift between this table, `KeyBindings.swift`,
/// the `BocanCommands*.swift` declarations, and the help book.
///
/// Negative test verified manually on 2026-08-11: renaming "Clear Queue"
/// here to "Clear Playback Queue" failed the crawl with `Playback:
/// expected "Clear Playback Queue", found "Clear Queue"` plus the full
/// observed tree.
enum MenuManifest {
    static let menus: [MenuSpec] = [
        MenuSpec(title: "Bòcan Music", items: [
            .own("About Bòcan"),
            .own("Check for Updates…"),
            .sys("Settings…"),
            .sys("Services", ignoreChildren: true),
            .sys("Hide Bòcan Music"),
            .sys("Hide Others"),
            .sys("Show All"),
            .sys("Quit Bòcan Music"),
            .sys("Quit and Keep Windows"),
        ]),
        MenuSpec(title: "File", items: [
            .own("New Playlist…", key: "⇧⌘N", binding: "newPlaylist", row: "New Playlist"),
            .own("New Smart Playlist…", key: "⌥⌘N", binding: "newSmartPlaylist"),
            .own("New Playlist Folder…"),
            .own(
                "Add Folder to Library…",
                key: "⇧⌘O",
                binding: "addFolder",
                row: "Add Folder to Library"
            ),
            .own("Add Files to Library…", key: "⌘O", binding: "addFiles"),
            .own("Music Sources…"),
            .own("Quick Rescan Library", key: "⌥⌘R"),
            .own("Full Rescan Library", key: "⌥⇧⌘R"),
            .own("Import Playlist…", key: "⌥⇧⌘O"),
            .sys("Close"),
            .sys("Close All"),
        ]),
        MenuSpec(title: "Edit", items: [
            .sys("Undo"),
            .sys("Redo"),
            .sys("Cut"),
            .sys("Copy"),
            .sys("Paste"),
            .sys("Delete"),
            .sys("Select All"),
            .own("Find", key: "⌘F", binding: "focusSearch", row: "Find"),
            .sys("AutoFill", ignoreChildren: true),
            .sys("Start Dictation…"),
            .sys("Emoji & Symbols"),
        ]),
        MenuSpec(title: "View", items: [
            .sys("Show Tab Bar", "Hide Tab Bar"),
            .sys("Show All Tabs", "Exit Tab Overview"),
            .sys("Show Sidebar", "Hide Sidebar"),
            .own("Show Lyrics", "Hide Lyrics", key: "⌥⌘L", row: "Show Lyrics"),
            .own("Show Visualizer", "Hide Visualizer", key: "⇧⌘V"),
            .own("Open Fullscreen Visualizer", key: "⇧⌘F"),
            .own("Toggle Miniplayer", key: "⌥⌘M", row: "Toggle Miniplayer"),
            .own("Show Recent Scrobbles", key: "⌥⇧⌘S"),
            .own("Equaliser & DSP…", key: "⌥⌘E", binding: "showEQPanel"),
            // The "View as" inline picker renders as a header row plus two
            // radio items at menu level.
            .own("View as"),
            .own("as List"),
            .own("as Album Grid"),
            .sys("Enter Full Screen", "Exit Full Screen"),
        ]),
        MenuSpec(title: "Playback", items: [
            .own("Play / Pause", key: "Space", binding: "playPause", row: "Play / Pause"),
            .own("Next Track", key: "⌘→", binding: "nextTrack", row: "Next Track"),
            .own("Previous Track", key: "⌘←", binding: "previousTrack", row: "Previous Track"),
            .own("Restart Track", key: "⌥⌘←", binding: "restartTrack"),
            .own("Mute", "Unmute", key: "⌥⌘Z", binding: "mute", row: "Mute / Unmute"),
            .own("Increase Volume", key: "⌘↑", binding: "increaseVolume"),
            .own("Decrease Volume", key: "⌘↓", binding: "decreaseVolume"),
            .own("Toggle Shuffle", key: "⇧⌘S", binding: "toggleShuffle", row: "Toggle Shuffle"),
            .own("Cycle Repeat", key: "⇧⌘E", binding: "cycleRepeat", row: "Cycle Repeat"),
            .own("Toggle Stop After Current", key: "⌥⌘.", binding: "stopAfterCurrent"),
            .own("Clear Queue", key: "⇧⌘⌫", binding: "clearQueue"),
            .own("Show Up Next", key: "⌥⌘U", binding: "showUpNext", row: "Show Up Next"),
            .own("Playback Speed", submenu: [
                // From NowPlayingViewModel.quickRates via PlaybackRateLabel;
                // "1.2×" here once meant the label lied about the 1.25 rate.
                .own("0.75×"),
                .own("1×"),
                .own("1.25×"),
                .own("1.5×"),
                .own("2×"),
            ]),
            .own("Increase Speed", key: "⌥⌘↑", binding: "increaseSpeed"),
            .own("Decrease Speed", key: "⌥⌘↓", binding: "decreaseSpeed"),
            .own("Reset Speed to 1×", key: "⌥⌘0", binding: "resetSpeed"),
            .own("Sleep Timer", submenu: [
                // NowPlayingViewModel.sleepPresets labels.
                .own("Off"),
                .own("15 min"),
                .own("30 min"),
                .own("45 min"),
                .own("1 hr"),
                .own("1 hr 30 min"),
                .own("2 hr"),
            ]),
            .own(
                "Jump to Current Track",
                key: "⌘J",
                binding: "jumpToCurrentTrack",
                row: "Jump to Current Track"
            ),
            .own("Go to Current Album", key: "⌥⌘A", binding: "goToCurrentAlbum"),
            .own("Go to Current Artist", key: "⌥⌘G", binding: "goToCurrentArtist"),
        ]),
        MenuSpec(title: "Track", items: [
            .own("Play Now", key: "⌘↩", binding: "playNow", row: "Play Selection Now"),
            .own("Play Next", key: "⇧⌘↩", binding: "playNext"),
            .own("Add to Queue", key: "⇧⌘Q", binding: "addToQueue"),
            .own("Play Album"),
            .own("Shuffle Album"),
            .own("Play Artist"),
            .own("Get Info", key: "⌘I", binding: "getInfo", row: "Get Info"),
            .own("Identify Track…", key: "⌥⌘I"),
            .own("Reveal in Finder", key: "⌘R", binding: "revealInFinder", row: "Reveal in Finder"),
            .own("Love / Unlove", key: "⌘L", binding: "love", row: "Love / Unlove"),
            .own("Rate", submenu: [
                .own("None", key: "⌘0"),
                .own("★", key: "⌘1", binding: "rate1"),
                .own("★★", key: "⌘2", binding: "rate2"),
                .own("★★★", key: "⌘3", binding: "rate3"),
                .own("★★★★", key: "⌘4", binding: "rate4"),
                .own("★★★★★", key: "⌘5", binding: "rate5"),
            ]),
            .own("Compute Replay Gain"),
            .own("Select All", key: "⌘A", binding: "selectAll"),
            .own("Deselect All", key: "⇧⌘A", binding: "deselectAll"),
            .own("Edit Lyrics…", key: "⌥⇧⌘L"),
            // Present iff `lyrics.lrclibEnabled`; the crawl launch pins the
            // flag on via the argument domain so the item is exercised.
            .own("Fetch Lyrics from LRClib"),
            .own("Clear Lyrics"),
        ]),
        MenuSpec(title: "Tools", items: [
            .own("Fetch Missing Cover Art…"),
            .own("Find Duplicates…"),
            .own("Compute Missing ReplayGain"),
            .own("Recompute ReplayGain"),
            .own("Analyse Provenance…"),
            .own("Import Last.fm History…"),
            .own("Library Summary…", key: "⇧⌘Y", binding: "librarySummary", row: "Library Summary"),
        ]),
        // Window is wholly system-managed plus SwiftUI's auto-generated
        // open-window items; contents are machine- and state-dependent.
        MenuSpec(title: "Window", crawlContents: false),
        MenuSpec(title: "Help", items: [
            .own("Bòcan Music Help", key: "⌘?"),
            .own("Notices & Licences…"),
            .own("Log Console", key: "⇧⌘L", row: "Log Console"),
        ]),
    ]

    /// Launch-argument defaults overrides that make the menu tree
    /// deterministic regardless of the machine's real preferences (E2E
    /// launches share the container's `UserDefaults`; see phase 32).
    static let pinnedDefaults = ["-lyrics.lrclibEnabled", "YES"]

    /// Every spec in the manifest, submenus included.
    static var allItems: [MenuItemSpec] {
        func flatten(_ specs: [MenuItemSpec]) -> [MenuItemSpec] {
            specs.flatMap { [$0] + flatten($0.submenu) }
        }
        return self.menus.flatMap { flatten($0.items) }
    }
}
