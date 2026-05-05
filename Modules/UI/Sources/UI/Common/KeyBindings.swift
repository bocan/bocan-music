import SwiftUI

/// Centralised keyboard shortcut definitions.
///
/// Bind these via `.keyboardShortcut(KeyBindings.focusSearch)` on buttons,
/// or via `CommandMenu` / `.commands { }` in the `App` body for global shortcuts.
public enum KeyBindings {
    // MARK: - Library import

    /// `⌘⇧O` — Add Folder to Library.
    public static let addFolder = KeyboardShortcut("o", modifiers: [.command, .shift])

    /// `⌘O` — Add Files to Library.
    public static let addFiles = KeyboardShortcut("o", modifiers: .command)

    // MARK: - Global

    /// `⌘F` — Focus the search field.
    public static let focusSearch = KeyboardShortcut("f", modifiers: .command)

    /// `Space` — Play / pause (when not in a text field).
    public static let playPause = KeyboardShortcut(" ", modifiers: [])

    // MARK: - Playback transport

    /// `⌘→` — Next track.
    public static let nextTrack = KeyboardShortcut(.rightArrow, modifiers: .command)

    /// `⌘←` — Previous track.
    public static let previousTrack = KeyboardShortcut(.leftArrow, modifiers: .command)

    /// `⌘⇧S` — Toggle shuffle.
    public static let toggleShuffle = KeyboardShortcut("s", modifiers: [.command, .shift])

    /// `⌘⇧E` — Cycle repeat (off → all → one → off).
    public static let cycleRepeat = KeyboardShortcut("e", modifiers: [.command, .shift])

    /// `⌘⌥.` — Toggle stop-after-current.
    public static let stopAfterCurrent = KeyboardShortcut(".", modifiers: [.command, .option])

    /// `⌘⇧⌫` — Clear the playback queue.
    public static let clearQueue = KeyboardShortcut(.delete, modifiers: [.command, .shift])

    /// `⌘⌥Z` — Mute / unmute.
    public static let mute = KeyboardShortcut("z", modifiers: [.command, .option])

    /// `⌘⌥A` — Go to the album of the currently-playing track.
    public static let goToCurrentAlbum = KeyboardShortcut("a", modifiers: [.command, .option])

    /// `⌘J` — Jump to the currently-playing track in the track list.
    public static let jumpToCurrentTrack = KeyboardShortcut("j", modifiers: .command)

    /// `⌘⌥G` — Go to the artist of the currently-playing track.
    public static let goToCurrentArtist = KeyboardShortcut("g", modifiers: [.command, .option])

    /// `⌘⌥U` — Reveal the Up Next sidebar destination.
    public static let showUpNext = KeyboardShortcut("u", modifiers: [.command, .option])

    /// `⌘⇧N` — New playlist (Phase 6).
    public static let newPlaylist = KeyboardShortcut("n", modifiers: [.command, .shift])

    /// `⌘⌥N` — New smart playlist (Phase 7).
    public static let newSmartPlaylist = KeyboardShortcut("n", modifiers: [.command, .option])

    /// `⌘I` — Get info / tag editor (Phase 8).
    public static let getInfo = KeyboardShortcut("i", modifiers: .command)

    /// `⌘R` — Reveal in Finder.
    public static let revealInFinder = KeyboardShortcut("r", modifiers: .command)

    /// `⌘L` — Love / unlove.
    public static let love = KeyboardShortcut("l", modifiers: .command)

    // MARK: - Rating (⌘1…5)

    /// `⌘1` — Rate 1 star.
    public static let rate1 = KeyboardShortcut("1", modifiers: .command)
    /// `⌘2` — Rate 2 stars.
    public static let rate2 = KeyboardShortcut("2", modifiers: .command)
    /// `⌘3` — Rate 3 stars.
    public static let rate3 = KeyboardShortcut("3", modifiers: .command)
    /// `⌘4` — Rate 4 stars.
    public static let rate4 = KeyboardShortcut("4", modifiers: .command)
    /// `⌘5` — Rate 5 stars.
    public static let rate5 = KeyboardShortcut("5", modifiers: .command)

    /// `⌘↩` — Play selected tracks now (replacing the queue).
    public static let playNow = KeyboardShortcut(.return, modifiers: .command)

    /// `⌘⇧↩` — Insert selected tracks immediately after the current item.
    public static let playNext = KeyboardShortcut(.return, modifiers: [.command, .shift])

    /// `⌘⇧Q` — Append selected tracks to the end of the queue.
    public static let addToQueue = KeyboardShortcut("q", modifiers: [.command, .shift])

    /// `⌘⌥↑` — Increase playback speed to the next quick rate.
    public static let increaseSpeed = KeyboardShortcut(.upArrow, modifiers: [.command, .option])

    /// `⌘⌥↓` — Decrease playback speed to the previous quick rate.
    public static let decreaseSpeed = KeyboardShortcut(.downArrow, modifiers: [.command, .option])

    /// `⌘⌥0` — Reset playback speed to 1×.
    public static let resetSpeed = KeyboardShortcut("0", modifiers: [.command, .option])

    /// `⌘⌥E` — Open or close the Equaliser & DSP panel.
    public static let showEQPanel = KeyboardShortcut("e", modifiers: [.command, .option])

    // MARK: - Selection

    /// `⌘A` — Select all visible tracks.
    public static let selectAll = KeyboardShortcut("a", modifiers: .command)

    /// `⌘⇧A` — Deselect all tracks.
    public static let deselectAll = KeyboardShortcut("a", modifiers: [.command, .shift])

    // MARK: - Navigation

    /// `⌥⌘→` — Drill into content (album / artist detail).
    public static let drillIn = KeyboardShortcut(.rightArrow, modifiers: [.option, .command])

    /// `⌥⌘←` — Navigate back.
    public static let drillOut = KeyboardShortcut(.leftArrow, modifiers: [.option, .command])
}
