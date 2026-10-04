import Foundation

// MARK: - HelpSection

/// The pages of the Help window, in sidebar order: guides first, reference after.
enum HelpSection: String, CaseIterable, Hashable {
    case gettingStarted = "Getting Started"
    case podcasts = "Podcasts"
    case internetRadio = "Internet Radio"
    case subsonic = "Subsonic Servers"
    case shortcuts = "Keyboard Shortcuts"
    case mouseButtons = "Mouse Buttons"
    case formats = "Supported Formats"

    /// Catalog key of the page title.
    var title: String {
        self.rawValue
    }

    var icon: String {
        Self.icons[self] ?? "questionmark.circle"
    }

    private static let icons: [Self: String] = [
        .gettingStarted: "questionmark.circle",
        .podcasts: "mic",
        .internetRadio: "dot.radiowaves.left.and.right",
        .subsonic: "server.rack",
        .shortcuts: "keyboard",
        .mouseButtons: "computermouse",
        .formats: "music.note.list",
    ]
}

// MARK: - HelpTopic

/// One heading and its paragraph. Both strings are catalog keys.
struct HelpTopic: Equatable {
    let title: String
    let body: String
}

// MARK: - HelpContent

/// All the prose of the Help window. This is the only help text the app ships
/// (the Apple Help Book went in 2026-10: nothing opened it and macOS never
/// indexed it), so a feature's help topic belongs here.
///
/// Every string is a key in `Resources/Localizable.xcstrings`, marked
/// `manual` there because the keys reach `L10n` through variables and Xcode
/// cannot extract them. `HelpContentTests` fails when a string here has no
/// catalog entry. The E2E `ShortcutParityTests` reads this file as text and
/// checks every shortcut it mentions against the menus.
enum HelpContent {
    static let gettingStarted: [HelpTopic] = [
        HelpTopic(
            title: "Add music to your library",
            body: "Choose File → Add Folder to Library… (⌘⇧O) or File → Add Files to Library…"
                + " to point Bòcan at your music. The library scanner indexes audio files and"
                + " reads their tags automatically."
        ),
        HelpTopic(
            title: "Playing tracks",
            body: "Double-click any track to start playback."
                + " Use Space to play/pause, ⌘→ for next track, and ⌘← for previous."
        ),
        HelpTopic(
            title: "Up Next queue",
            body: "Right-click tracks and choose Add to Queue, or drag them onto the Up Next"
                + " sidebar section. View the queue under Playback → Show Up Next (⌘⌥U)."
        ),
        HelpTopic(
            title: "Editing track info",
            body: "Select one or more tracks and press ⌘I, or choose Track → Get Info."
                + " The editor lets you update tags, artwork, and lyrics for a single track or in bulk."
        ),
        HelpTopic(
            title: "Playlists",
            body: "Create standard playlists with File → New Playlist… (⌘⇧N)"
                + " or rules-based Smart Playlists with File → New Smart Playlist… (⌘⌥N)."
                + " Import M3U, PLS, and XSPF playlists via File → Import Playlist…"
        ),
        HelpTopic(
            title: "Search as you type",
            body: "Just start typing over any library view: the first letter jumps into the search"
                + " field and the query builds from there. ⌘F focuses the field too, ⌘A selects"
                + " your typed text for replacing, and Esc leaves the search."
        ),
        HelpTopic(
            title: "Moving around",
            body: "The toolbar's back and forward arrows walk your browsing history, and the back"
                + " and forward side buttons on a mouse do the same. Esc backs out of whatever you"
                + " drilled into: an album returns to the artist you opened it from, then to Artists."
        ),
        HelpTopic(
            title: "Lyrics",
            body: "Toggle the lyrics panel with ⌘⌥L."
                + " Bòcan displays embedded LRC timestamps when available and scrolls in sync with playback."
        ),
        HelpTopic(
            title: "Miniplayer",
            body: "Switch to the compact window with ⌘⌥M or View → Toggle Miniplayer."
        ),
        HelpTopic(
            title: "Scrobbling",
            body: "Connect your Last.fm, ListenBrainz, or Rocksky account under Bòcan → Settings… → Scrobbling"
                + " to enable automatic track scrobbling."
        ),
        HelpTopic(
            title: "Viewing logs",
            body: "Choose Help → Log Console (⌘⇧L) to open the in-app log console. It shows every log"
                + " line since launch and tails new ones live. Filter by level or category, search the"
                + " message text, pause, copy, or export to a .log file for attaching to a bug report."
                + " To stop the buffer from filling while the app runs unattended, turn off"
                + " Capture in-app logs under Bòcan → Settings… → Diagnostics."
        ),
    ]

    static let podcasts: [HelpTopic] = [
        HelpTopic(
            title: "Subscribing to a podcast",
            body: "Click the Podcasts item in the sidebar. Type a show name into the field at the top,"
                + " or paste a feed URL there."
                + " Bòcan checks Podcast Index and the Apple iTunes catalogue."
        ),
        HelpTopic(
            title: "Browsing episodes",
            body: "Click any show in the Podcasts sidebar section to open the episode list."
                + " Episodes are listed newest first, or oldest first for a serial show; change the"
                + " order in the show's settings. A download button appears next to each"
                + " undownloaded episode."
        ),
        HelpTopic(
            title: "Downloading episodes",
            body: "Click the download button on an episode row to save it locally. Downloaded episodes"
                + " play from disk and are available offline. Bòcan can download new episodes of a show"
                + " by itself: switch that on in the show's settings, and set how many under"
                + " Settings → Podcasts."
        ),
        HelpTopic(
            title: "Marking episodes played",
            body: "Right-click an episode to mark it played or unplayed. To change several at once,"
                + " select them with Shift-click or Command-click, then right-click and choose Mark"
                + " Selected as Played or Mark Selected as Unplayed. Download Selected and Remove"
                + " Downloads work on a selection the same way. To mark a whole show played, use Mark"
                + " All as Played on the show's page."
        ),
        HelpTopic(
            title: "Resuming playback",
            body: "Bòcan remembers your position in every episode."
                + " Play the episode again to resume from where you left off."
        ),
        HelpTopic(
            title: "Skip intervals and playback speed",
            body: "While a podcast is playing, the transport bar shows skip-back and skip-forward buttons"
                + " instead of previous and next track. The default intervals are 15 seconds back and"
                + " 30 seconds forward. Change these under Settings → Podcasts → Playback. You can also"
                + " set a default playback speed for podcasts independently of the speed used for music."
        ),
    ]

    static let internetRadio: [HelpTopic] = [
        HelpTopic(
            title: "Adding a station",
            body: "Click Radio in the sidebar, then Add Station. Paste a stream URL, give it a name if"
                + " you like (Bòcan fills one in from the station itself after the first listen), and add."
        ),
        HelpTopic(
            title: "Adding a whole station list at once",
            body: "Paste a .m3u or .pls playlist link into the Stream or Playlist URL field and every"
                + " station inside is offered with its name intact. Importing or dropping a playlist file"
                + " works too: its stream entries become stations, and any local tracks still become a"
                + " normal playlist."
        ),
        HelpTopic(
            title: "Now playing",
            body: "While a station plays, the song title arrives live from the stream and the station"
                + " name moves to the artist line. Live radio has no timeline, so there is no seeking,"
                + " and stations never scrobble or touch your play history. If a stream drops, Bòcan"
                + " reconnects on its own before giving up."
        ),
        HelpTopic(
            title: "Stream details",
            body: "Click the info button in the player (or the i on any station row) to see what you're"
                + " hearing: codec, sample rate, channels, the bitrate the station claims, and whether it"
                + " sends song titles. Details are remembered per station, so the sheet works offline too."
        ),
    ]

    static let mouseButtons: [HelpTopic] = [
        HelpTopic(
            title: "Back and forward buttons",
            body: "The thumb buttons on a multi-button mouse walk your browse history,"
                + " exactly like a web browser: the back button returns to the previous"
                + " view, the forward button revisits it. They mirror the toolbar's"
                + " chevron buttons and the ⌘[ and ⌘] shortcuts."
        ),
        HelpTopic(
            title: "Escape backs out of a drill-down",
            body: "Press Esc inside an album, artist, genre, or composer detail view to"
                + " return to its parent listing. Esc never jumps across sidebar sections;"
                + " it only climbs out of the current drill-down."
        ),
        HelpTopic(
            title: "Logitech mice and Logi Options+",
            body: "Logi Options+ intercepts the thumb buttons before they reach Bòcan, so"
                + " back and forward may do nothing even though the hardware supports them."
                + " To fix it, open Logi Options+, add Bòcan as an application profile, and"
                + " assign the thumb buttons the keystrokes ⌘[ (back) and ⌘] (forward)."
                + " Without Options+ installed, the buttons work with no setup."
        ),
    ]

    static let subsonicIntro = "Bòcan treats Subsonic-compatible servers (including Navidrome and Airsonic)"
        + " as first-class sources alongside your local library."

    static let subsonic: [HelpTopic] = [
        HelpTopic(
            title: "Adding a server",
            body: "Open Bòcan → Settings… → Sources, then click Add Server."
                + " Enter the server URL (including https://), a username, and a password."
                + " Credentials are stored in the macOS Keychain; the password is never written to"
                + " the library or to preferences."
                + " You can add more than one Subsonic, Navidrome, or Airsonic server."
        ),
        HelpTopic(
            title: "Connection status dots",
            body: "Each server in the sidebar shows its state:"
                + " a spinner = connecting, green = online, orange = authentication failed,"
                + " red = unreachable or server error, grey = not checked yet. Every dot has a"
                + " VoiceOver label announcing the server name and current state."
        ),
        HelpTopic(
            title: "Offline banner",
            body: "When a server you are browsing goes offline, an orange banner appears"
                + " at the top of the content area with a Retry now button. Other servers"
                + " and your local library continue to work normally."
        ),
        HelpTopic(
            title: "Browsing",
            body: "Each server has its own sidebar section: Songs, Albums, Artists, Genres, Playlists,"
                + " Starred, Random, Recently Added and Most Played, plus Internet Radio, Podcasts and"
                + " Bookmarks when the server supports them. Bòcan checks what a server supports at"
                + " launch, at most once a day, and when you click Test Connection in Settings → Sources."
        ),
        HelpTopic(
            title: "Federated search",
            body: "Press ⌘F in a server's Songs, Albums or Artists view and start typing. Bòcan searches"
                + " every server that has Include in global search switched on, in parallel, and a"
                + " Source column shows which server each result is from."
        ),
        HelpTopic(
            title: "Stars and ratings",
            body: "Starring a track or setting a 1–5 star rating writes back to the server"
                + " via the standard Subsonic star and setRating calls. Changes appear on the"
                + " server immediately and survive a relaunch."
        ),
        HelpTopic(
            title: "Streaming and scrobbling",
            body: "Tracks play through the same gapless audio engine as local files."
                + " Bòcan downloads each track completely before it starts, so seeking is exact."
                + " Scrobbles are sent both to the server's own scrobble endpoint and to your"
                + " configured Last.fm, ListenBrainz, or Rocksky accounts."
        ),
        HelpTopic(
            title: "Server shortcuts",
            body: "⌘⇧1 through ⌘⇧9 expand or collapse the first nine servers in the sidebar,"
                + " in the order they appear there."
        ),
    ]

    static let formatsIntro = "Bòcan plays all formats supported by macOS Core Audio"
        + " plus additional formats via its built-in FFmpeg engine."

    /// Engine name and the formats it plays.
    static let formatRows: [HelpTopic] = [
        HelpTopic(
            title: "Core Audio",
            body: "FLAC, ALAC/M4A, MP3, AAC, AIFF, WAV"
        ),
        HelpTopic(
            title: "FFmpeg engine",
            body: "OGG Vorbis / Speex / Ogg FLAC, Opus, MP2/MP1, AC-3, DTS, WMA,"
                + " Wave64, RF64, Matroska/MKV/WebM, AU/SND,"
                + " APE (Monkey's Audio), WavPack, DSD (DSF/DFF)"
        ),
    ]

    static let formatsTags = "Tag formats: ID3v2 (MP3), Vorbis Comments (FLAC/OGG/Opus),"
        + " MP4/iTunes tags (M4A/AAC), APEv2."

    /// The topics of a prose page; empty for the two pages with their own layout.
    static func topics(for section: HelpSection) -> [HelpTopic] {
        self.topicsBySection[section] ?? []
    }

    private static let topicsBySection: [HelpSection: [HelpTopic]] = [
        .gettingStarted: gettingStarted,
        .podcasts: podcasts,
        .internetRadio: internetRadio,
        .subsonic: subsonic,
        .mouseButtons: mouseButtons,
    ]

    /// The paragraph under a page title, where the page has one.
    static func intro(for section: HelpSection) -> String? {
        self.intros[section]
    }

    private static let intros: [HelpSection: String] = [
        .subsonic: subsonicIntro,
        .formats: formatsIntro,
    ]

    /// Every catalog key the Help window can show.
    static var allKeys: [String] {
        var keys: [String] = HelpSection.allCases.map(\.title)
        for topic in HelpSection.allCases.flatMap({ self.topics(for: $0) }) + self.formatRows {
            keys.append(topic.title)
            keys.append(topic.body)
        }
        keys += [self.subsonicIntro, self.formatsIntro, self.formatsTags, HelpShortcuts.spaceKey]
        for group in HelpShortcuts.groups {
            keys.append(group.title)
            keys += group.shortcuts.map(\.action)
        }
        return keys
    }
}
