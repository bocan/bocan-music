import Foundation

// MARK: - HelpShortcut

/// One row of the Keyboard Shortcuts page. `action` is a catalog key; `key`
/// is the shortcut as shown, in symbols.
struct HelpShortcut: Equatable {
    let action: String
    let key: String
}

// MARK: - HelpShortcutGroup

struct HelpShortcutGroup {
    /// Catalog key of the group heading.
    let title: String
    let shortcuts: [HelpShortcut]
}

// MARK: - HelpShortcuts

/// The Keyboard Shortcuts table of the Help window.
///
/// Keys mirror `KeyBindings.swift` and the `BocanCommands` menu bindings. The
/// E2E `ShortcutParityTests` parses the `HelpShortcut(action:key:)` rows below
/// as text and compares each one with the menu manifest, so keep one row per
/// line in exactly this form.
enum HelpShortcuts {
    /// The one key shown as a word, so it is the one key that is localized.
    static let spaceKey = "Space"

    static let groups: [HelpShortcutGroup] = [
        HelpShortcutGroup(title: "Playback", shortcuts: [
            HelpShortcut(action: "Play / Pause", key: "Space"),
            HelpShortcut(action: "Play Selection Now", key: "⌘↩"),
            HelpShortcut(action: "Play Selection Next", key: "⌘⇧↩"),
            HelpShortcut(action: "Add Selection to Queue", key: "⌘⇧Q"),
            HelpShortcut(action: "Next Track", key: "⌘→"),
            HelpShortcut(action: "Previous Track", key: "⌘←"),
            HelpShortcut(action: "Restart Track", key: "⌘⌥←"),
            HelpShortcut(action: "Stop After Current", key: "⌘⌥."),
            HelpShortcut(action: "Toggle Shuffle", key: "⌘⇧S"),
            HelpShortcut(action: "Cycle Repeat", key: "⌘⇧E"),
            HelpShortcut(action: "Increase Speed", key: "⌘⌥↑"),
            HelpShortcut(action: "Decrease Speed", key: "⌘⌥↓"),
            HelpShortcut(action: "Reset Speed", key: "⌘⌥0"),
        ]),
        HelpShortcutGroup(title: "Volume", shortcuts: [
            HelpShortcut(action: "Increase Volume", key: "⌘↑"),
            HelpShortcut(action: "Decrease Volume", key: "⌘↓"),
            HelpShortcut(action: "Mute / Unmute", key: "⌘⌥Z"),
        ]),
        HelpShortcutGroup(title: "Navigation & View", shortcuts: [
            HelpShortcut(action: "Back", key: "⌘["),
            HelpShortcut(action: "Forward", key: "⌘]"),
            HelpShortcut(action: "Find", key: "⌘F"),
            HelpShortcut(action: "Select All", key: "⌘A"),
            HelpShortcut(action: "Deselect All", key: "⌘⇧A"),
            HelpShortcut(action: "Jump to Current Track", key: "⌘J"),
            HelpShortcut(action: "Go to Current Album", key: "⌘⌥A"),
            HelpShortcut(action: "Go to Current Artist", key: "⌘⌥G"),
            HelpShortcut(action: "Show Up Next", key: "⌘⌥U"),
            HelpShortcut(action: "Show Lyrics", key: "⌘⌥L"),
            HelpShortcut(action: "Show Visualizer", key: "⌘⇧V"),
            HelpShortcut(action: "Open Fullscreen Visualizer", key: "⌘⇧F"),
            HelpShortcut(action: "Enter Immersive Mode", key: "⌘⇧I"),
            HelpShortcut(action: "Toggle Miniplayer", key: "⌘⌥M"),
        ]),
        HelpShortcutGroup(title: "Library & Playlists", shortcuts: [
            HelpShortcut(action: "Add Files to Library", key: "⌘O"),
            HelpShortcut(action: "Add Folder to Library", key: "⌘⇧O"),
            HelpShortcut(action: "Import Playlist", key: "⌘⌥⇧O"),
            HelpShortcut(action: "New Playlist", key: "⌘⇧N"),
            HelpShortcut(action: "New Smart Playlist", key: "⌘⌥N"),
            HelpShortcut(action: "Quick Rescan Library", key: "⌘⌥R"),
            HelpShortcut(action: "Full Rescan Library", key: "⌘⌥⇧R"),
            HelpShortcut(action: "Library Summary", key: "⌘⇧Y"),
        ]),
        HelpShortcutGroup(title: "Tracks", shortcuts: [
            HelpShortcut(action: "Get Info", key: "⌘I"),
            HelpShortcut(action: "Love / Unlove", key: "⌘L"),
            HelpShortcut(action: "Clear Rating", key: "⌘0"),
            HelpShortcut(action: "Rate 1–5 Stars", key: "⌘1–⌘5"),
            HelpShortcut(action: "Identify Track", key: "⌘⌥I"),
            HelpShortcut(action: "Reveal in Finder", key: "⌘R"),
        ]),
        HelpShortcutGroup(title: "Queue, Windows & Tools", shortcuts: [
            HelpShortcut(action: "Clear Queue", key: "⌘⇧⌫"),
            HelpShortcut(action: "Equaliser & DSP", key: "⌘⌥E"),
            HelpShortcut(action: "Show Recent Scrobbles", key: "⌘⌥⇧S"),
            HelpShortcut(action: "Log Console", key: "⌘⇧L"),
            HelpShortcut(action: "Bòcan Music Help", key: "⌘?"),
        ]),
    ]
}
