import Foundation

// MARK: - MenuState

/// The app states of the phase 30 enablement matrix. The matrix test
/// scripts each state through the UI (clicks and keystrokes, never by
/// writing defaults: `BocanCommands` reads live view-model state at menu
/// validation, and defaults-poking would test a lie).
enum MenuState: String, CaseIterable {
    /// Fixture launch, scan settled, nothing selected, nothing playing.
    case freshLaunch
    /// One library track row selected; still nothing playing.
    case trackSelected
    /// A library track playing (selection retained).
    case trackPlaying
    /// The toolbar search field focused with text in it (the ⌘A row).
    case searchFieldFocused
    /// A seeded internet-radio queue restored as current, not playing.
    case radioCurrent
}

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
    /// Expected enablement per matrix state; unlisted states are not
    /// asserted (dynamic or irrelevant there).
    var enablement: [MenuState: Bool] = [:]
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
        enablement: [MenuState: Bool] = [:],
        submenu: [MenuItemSpec] = []
    ) -> MenuItemSpec {
        MenuItemSpec(
            titles: titles,
            shortcut: key.map { MenuShortcut.fromDisplay($0)! },
            binding: binding,
            helpBookRow: row,
            conditional: conditional,
            enablement: enablement,
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
            // Sparkle cannot check in unsigned debug/E2E builds.
            .own("Check for Updates…", enablement: [.freshLaunch: false]),
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
            // Disabled only while a scan runs; fresh-launch assertion
            // doubles as the "scan settled" gate (the matrix retries).
            .own("Quick Rescan Library", key: "⌥⌘R", enablement: [.freshLaunch: true]),
            .own("Full Rescan Library", key: "⌥⇧⌘R", enablement: [.freshLaunch: true]),
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
            // radio items at menu level. The options are only meaningful on
            // the Artists/Genres/Composers listings; the fresh launch shows
            // Songs, so all three rows must be disabled there.
            .own("View as", enablement: [.freshLaunch: false]),
            .own("as List", enablement: [.freshLaunch: false]),
            .own("as Album Grid", enablement: [.freshLaunch: false]),
            .sys("Enter Full Screen", "Exit Full Screen"),
        ]),
        MenuSpec(title: "Playback", items: [
            .own("Play / Pause", key: "Space", binding: "playPause", row: "Play / Pause"),
            .own(
                "Next Track",
                key: "⌘→",
                binding: "nextTrack",
                row: "Next Track",
                enablement: [.freshLaunch: false, .trackSelected: false, .trackPlaying: true]
            ),
            .own(
                "Previous Track",
                key: "⌘←",
                binding: "previousTrack",
                row: "Previous Track",
                enablement: [.freshLaunch: false, .trackPlaying: true]
            ),
            .own(
                "Restart Track",
                key: "⌥⌘←",
                binding: "restartTrack",
                enablement: [.freshLaunch: false, .trackPlaying: true]
            ),
            .own("Mute", "Unmute", key: "⌥⌘Z", binding: "mute", row: "Mute / Unmute"),
            .own("Increase Volume", key: "⌘↑", binding: "increaseVolume"),
            .own("Decrease Volume", key: "⌘↓", binding: "decreaseVolume"),
            .own("Toggle Shuffle", key: "⇧⌘S", binding: "toggleShuffle", row: "Toggle Shuffle"),
            .own("Cycle Repeat", key: "⇧⌘E", binding: "cycleRepeat", row: "Cycle Repeat"),
            .own(
                "Toggle Stop After Current",
                key: "⌥⌘.",
                binding: "stopAfterCurrent",
                enablement: [.freshLaunch: false, .trackPlaying: true]
            ),
            // A restored radio queue is still a queue: it must be
            // clearable from the menu even though no library track is
            // current.
            .own(
                "Clear Queue",
                key: "⇧⌘⌫",
                binding: "clearQueue",
                enablement: [.freshLaunch: false, .trackPlaying: true, .radioCurrent: true]
            ),
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
                row: "Jump to Current Track",
                enablement: [.freshLaunch: false, .trackPlaying: true, .radioCurrent: false]
            ),
            // A radio stream has no album or artist rows to go to.
            .own(
                "Go to Current Album",
                key: "⌥⌘A",
                binding: "goToCurrentAlbum",
                enablement: [.freshLaunch: false, .trackPlaying: true, .radioCurrent: false]
            ),
            .own(
                "Go to Current Artist",
                key: "⌥⌘G",
                binding: "goToCurrentArtist",
                enablement: [.freshLaunch: false, .trackPlaying: true, .radioCurrent: false]
            ),
        ]),
        MenuSpec(title: "Track", items: [
            .own(
                "Play Now",
                key: "⌘↩",
                binding: "playNow",
                row: "Play Selection Now",
                enablement: [.freshLaunch: false, .trackSelected: true, .radioCurrent: false]
            ),
            .own(
                "Play Next",
                key: "⇧⌘↩",
                binding: "playNext",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Add to Queue",
                key: "⇧⌘Q",
                binding: "addToQueue",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own("Play Album", enablement: [.freshLaunch: false, .trackSelected: true]),
            .own("Shuffle Album", enablement: [.freshLaunch: false, .trackSelected: true]),
            .own("Play Artist", enablement: [.freshLaunch: false, .trackSelected: true]),
            // Selection-scoped like their siblings: all three no-op
            // without a selection, so they must be disabled without one.
            .own(
                "Get Info",
                key: "⌘I",
                binding: "getInfo",
                row: "Get Info",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Identify Track…",
                key: "⌥⌘I",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Reveal in Finder",
                key: "⌘R",
                binding: "revealInFinder",
                row: "Reveal in Finder",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Love / Unlove",
                key: "⌘L",
                binding: "love",
                row: "Love / Unlove",
                enablement: [.freshLaunch: false, .trackSelected: true, .radioCurrent: false]
            ),
            // SwiftUI leaves a `.disabled` Menu parent enabled and greys
            // its children instead, so the matrix rows sit on the children.
            .own("Rate", submenu: [
                .own("None", key: "⌘0", enablement: [.freshLaunch: false, .trackSelected: true]),
                .own("★", key: "⌘1", binding: "rate1", enablement: [.freshLaunch: false, .trackSelected: true]),
                .own("★★", key: "⌘2", binding: "rate2"),
                .own("★★★", key: "⌘3", binding: "rate3"),
                .own("★★★★", key: "⌘4", binding: "rate4"),
                .own("★★★★★", key: "⌘5", binding: "rate5", enablement: [.trackSelected: true]),
            ]),
            .own(
                "Compute Replay Gain",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Select All",
                key: "⌘A",
                binding: "selectAll",
                enablement: [.freshLaunch: true]
            ),
            .own(
                "Deselect All",
                key: "⇧⌘A",
                binding: "deselectAll",
                enablement: [.freshLaunch: false, .trackSelected: true]
            ),
            .own(
                "Edit Lyrics…",
                key: "⌥⇧⌘L",
                enablement: [.freshLaunch: false, .trackPlaying: true, .radioCurrent: false]
            ),
            // Present iff `lyrics.lrclibEnabled`; the crawl launch pins the
            // flag on via the argument domain so the item is exercised.
            .own("Fetch Lyrics from LRClib"),
            // Fixture tones carry no lyrics, so there is nothing to clear
            // even while one plays (LRClib is pinned off in the matrix).
            .own(
                "Clear Lyrics",
                enablement: [.freshLaunch: false, .trackPlaying: false]
            ),
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

    /// The enablement matrix pins LRClib *off* instead: it plays a track,
    /// and with the flag on the app would fire a real lyrics lookup for
    /// the fixture tone (tests must not hit the network).
    static let matrixDefaults = ["-lyrics.lrclibEnabled", "NO"]

    /// Every spec in the manifest, submenus included.
    static var allItems: [MenuItemSpec] {
        func flatten(_ specs: [MenuItemSpec]) -> [MenuItemSpec] {
            specs.flatMap { [$0] + flatten($0.submenu) }
        }
        return self.menus.flatMap { flatten($0.items) }
    }
}
