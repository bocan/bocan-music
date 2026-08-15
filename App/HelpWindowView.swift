import SwiftUI

// MARK: - HelpWindowView

/// In-app help reference shown from Help → Bòcan Music Help.
struct HelpWindowView: View {
    // MARK: - HelpSection

    private enum HelpSection: String, CaseIterable, Hashable {
        case gettingStarted = "Getting Started"
        case shortcuts = "Keyboard Shortcuts"
        case mouseButtons = "Mouse Buttons"
        case formats = "Supported Formats"
        case subsonic = "Subsonic Servers"

        var icon: String {
            switch self {
            case .gettingStarted:
                "questionmark.circle"

            case .shortcuts:
                "keyboard"

            case .mouseButtons:
                "computermouse"

            case .formats:
                "music.note.list"

            case .subsonic:
                "server.rack"
            }
        }
    }

    @State private var selection: HelpSection? = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(HelpSection.allCases, id: \.self, selection: self.$selection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            self.detailView
        }
    }

    // MARK: - Private

    private var detailView: some View {
        ScrollView {
            switch self.selection ?? .gettingStarted {
            case .gettingStarted:
                GettingStartedSection()

            case .shortcuts:
                ShortcutsSection()

            case .mouseButtons:
                MouseButtonsSection()

            case .formats:
                FormatsSection()

            case .subsonic:
                SubsonicSection()
            }
        }
    }
}

// MARK: - Section header helper

private func helpSectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.largeTitle)
        .fontWeight(.semibold)
        .padding(.bottom, 20)
}

// MARK: - GettingStartedSection

private struct GettingStartedSection: View {
    private struct Topic {
        let title: String
        let body: String
    }

    private static let topics: [Topic] = [
        Topic(
            title: "Add music to your library",
            body: "Choose File → Add Folder to Library… (⌘⇧O) or File → Add Files to Library…"
                + " to point Bòcan at your music. The library scanner indexes audio files and"
                + " reads their tags automatically."
        ),
        Topic(
            title: "Playing tracks",
            body: "Double-click any track to start playback."
                + " Use Space to play/pause, ⌘→ for next track, and ⌘← for previous."
        ),
        Topic(
            title: "Up Next queue",
            body: "Right-click tracks and choose Add to Queue, or drag them onto the Up Next"
                + " sidebar section. View the queue under Playback → Show Up Next (⌘⌥U)."
        ),
        Topic(
            title: "Editing track info",
            body: "Select one or more tracks and press ⌘I, or choose Track → Get Info."
                + " The editor lets you update tags, artwork, and lyrics for a single track or in bulk."
        ),
        Topic(
            title: "Playlists",
            body: "Create standard playlists with File → New Playlist… (⌘⇧N)"
                + " or rules-based Smart Playlists with File → New Smart Playlist… (⌘⌥N)."
                + " Import M3U, PLS, and XSPF playlists via File → Import Playlist…"
        ),
        Topic(
            title: "Lyrics",
            body: "Toggle the lyrics panel with ⌘⌥L."
                + " Bòcan displays embedded LRC timestamps when available and scrolls in sync with playback."
        ),
        Topic(
            title: "Miniplayer",
            body: "Switch to the compact window with ⌘⌥M or Window → Toggle Miniplayer."
        ),
        Topic(
            title: "Scrobbling",
            body: "Connect your Last.fm, Musicbrainz, or Rocksky account under Bòcan → Settings… → Scrobbling"
                + " to enable automatic track scrobbling."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Getting Started")
            ForEach(Self.topics, id: \.title) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(.headline)
                    Text(topic.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - ShortcutsSection

private struct ShortcutsSection: View {
    private struct Shortcut {
        let action: String
        let key: String
    }

    private struct ShortcutGroup {
        let title: String
        let shortcuts: [Shortcut]
    }

    /// Keys mirror KeyBindings.swift and the BocanCommands menu bindings; the
    /// HTML Help Book table (HelpBook/…/index.html) must list the identical
    /// rows, and HelpShortcutParityTests fails the build when they drift.
    private static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Playback", shortcuts: [
            Shortcut(action: "Play / Pause", key: "Space"),
            Shortcut(action: "Play Selection Now", key: "⌘↩"),
            Shortcut(action: "Play Selection Next", key: "⌘⇧↩"),
            Shortcut(action: "Add Selection to Queue", key: "⌘⇧Q"),
            Shortcut(action: "Next Track", key: "⌘→"),
            Shortcut(action: "Previous Track", key: "⌘←"),
            Shortcut(action: "Restart Track", key: "⌘⌥←"),
            Shortcut(action: "Stop After Current", key: "⌘⌥."),
            Shortcut(action: "Toggle Shuffle", key: "⌘⇧S"),
            Shortcut(action: "Cycle Repeat", key: "⌘⇧E"),
            Shortcut(action: "Increase Speed", key: "⌘⌥↑"),
            Shortcut(action: "Decrease Speed", key: "⌘⌥↓"),
            Shortcut(action: "Reset Speed", key: "⌘⌥0"),
        ]),
        ShortcutGroup(title: "Volume", shortcuts: [
            Shortcut(action: "Increase Volume", key: "⌘↑"),
            Shortcut(action: "Decrease Volume", key: "⌘↓"),
            Shortcut(action: "Mute / Unmute", key: "⌘⌥Z"),
        ]),
        ShortcutGroup(title: "Navigation & View", shortcuts: [
            Shortcut(action: "Back", key: "⌘["),
            Shortcut(action: "Forward", key: "⌘]"),
            Shortcut(action: "Find", key: "⌘F"),
            Shortcut(action: "Select All", key: "⌘A"),
            Shortcut(action: "Deselect All", key: "⌘⇧A"),
            Shortcut(action: "Jump to Current Track", key: "⌘J"),
            Shortcut(action: "Go to Current Album", key: "⌘⌥A"),
            Shortcut(action: "Go to Current Artist", key: "⌘⌥G"),
            Shortcut(action: "Show Up Next", key: "⌘⌥U"),
            Shortcut(action: "Show Lyrics", key: "⌘⌥L"),
            Shortcut(action: "Show Visualizer", key: "⌘⇧V"),
            Shortcut(action: "Open Fullscreen Visualizer", key: "⌘⇧F"),
            Shortcut(action: "Toggle Miniplayer", key: "⌘⌥M"),
        ]),
        ShortcutGroup(title: "Library & Playlists", shortcuts: [
            Shortcut(action: "Add Files to Library", key: "⌘O"),
            Shortcut(action: "Add Folder to Library", key: "⌘⇧O"),
            Shortcut(action: "Import Playlist", key: "⌘⌥⇧O"),
            Shortcut(action: "New Playlist", key: "⌘⇧N"),
            Shortcut(action: "New Smart Playlist", key: "⌘⌥N"),
            Shortcut(action: "Quick Rescan Library", key: "⌘⌥R"),
            Shortcut(action: "Full Rescan Library", key: "⌘⌥⇧R"),
            Shortcut(action: "Library Summary", key: "⌘⇧Y"),
        ]),
        ShortcutGroup(title: "Tracks", shortcuts: [
            Shortcut(action: "Get Info", key: "⌘I"),
            Shortcut(action: "Love / Unlove", key: "⌘L"),
            Shortcut(action: "Clear Rating", key: "⌘0"),
            Shortcut(action: "Rate 1–5 Stars", key: "⌘1–⌘5"),
            Shortcut(action: "Identify Track", key: "⌘⌥I"),
            Shortcut(action: "Reveal in Finder", key: "⌘R"),
        ]),
        ShortcutGroup(title: "Queue, Windows & Tools", shortcuts: [
            Shortcut(action: "Clear Queue", key: "⌘⇧⌫"),
            Shortcut(action: "Equaliser & DSP", key: "⌘⌥E"),
            Shortcut(action: "Show Recent Scrobbles", key: "⌘⌥⇧S"),
            Shortcut(action: "Log Console", key: "⌘⇧L"),
            Shortcut(action: "Bòcan Music Help", key: "⌘?"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Keyboard Shortcuts")
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(.headline)
                        .padding(.bottom, 6)
                    Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                        ForEach(group.shortcuts, id: \.action) { shortcut in
                            GridRow {
                                Text(shortcut.action)
                                    .gridColumnAlignment(.leading)
                                    .frame(minWidth: 220, alignment: .leading)
                                Text(shortcut.key)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - MouseButtonsSection

private struct MouseButtonsSection: View {
    private struct Topic {
        let title: String
        let body: String
    }

    private static let topics: [Topic] = [
        Topic(
            title: "Back and forward buttons",
            body: "The thumb buttons on a multi-button mouse walk your browse history,"
                + " exactly like a web browser: the back button returns to the previous"
                + " view, the forward button revisits it. They mirror the toolbar's"
                + " chevron buttons and the ⌘[ and ⌘] shortcuts."
        ),
        Topic(
            title: "Escape backs out of a drill-down",
            body: "Press Esc inside an album, artist, genre, or composer detail view to"
                + " return to its parent listing. Esc never jumps across sidebar sections;"
                + " it only climbs out of the current drill-down."
        ),
        Topic(
            title: "Logitech mice and Logi Options+",
            body: "Logi Options+ intercepts the thumb buttons before they reach Bòcan, so"
                + " back and forward may do nothing even though the hardware supports them."
                + " To fix it, open Logi Options+, add Bòcan as an application profile, and"
                + " assign the thumb buttons the keystrokes ⌘[ (back) and ⌘] (forward)."
                + " Without Options+ installed, the buttons work with no setup."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Mouse Buttons")
            ForEach(Self.topics, id: \.title) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(.headline)
                    Text(topic.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - FormatsSection

private struct FormatsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Supported Formats")
            Text(
                "Bòcan plays all formats supported by macOS Core Audio"
                    + " plus additional formats via its built-in FFmpeg engine."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 12) {
                FormatRow(
                    engine: "Core Audio",
                    formats: "FLAC, ALAC/M4A, MP3, AAC, AIFF, WAV, CAF"
                )
                FormatRow(
                    engine: "FFmpeg engine",
                    formats: "OGG Vorbis / Speex / Ogg FLAC, Opus, MP2/MP1, AC-3, DTS, WMA,"
                        + " Wave64, RF64, Matroska/MKV/WebM, AU/SND,"
                        + " APE (Monkey's Audio), WavPack, DSD (DSF/DFF)"
                )
            }
            .padding(.bottom, 20)

            Text(
                "Tag formats: ID3v2 (MP3), Vorbis Comments (FLAC/OGG/Opus),"
                    + " MP4/iTunes tags (M4A/AAC), APEv2."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - FormatRow

private struct FormatRow: View {
    let engine: String
    let formats: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.engine)
                .fontWeight(.semibold)
            Text(self.formats)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SubsonicSection

private struct SubsonicSection: View {
    private struct Topic {
        let title: String
        let body: String
    }

    private static let topics: [Topic] = [
        Topic(
            title: "Adding a server",
            body: "Open Bòcan → Settings… → Sources, then click Add Server."
                + " Enter the server URL (including https://), a username, and a password."
                + " Credentials are stored in the macOS Keychain; the password is never written to disk."
                + " You can connect up to nine Subsonic, Navidrome, or Airsonic servers."
        ),
        Topic(
            title: "Connection status dots",
            body: "Each server in the sidebar shows a coloured dot:"
                + " green = online, blue pulsing = connecting, orange = authentication failed,"
                + " grey = unreachable, red = server error. Every dot has a VoiceOver label"
                + " announcing the server name and current state."
        ),
        Topic(
            title: "Offline banner",
            body: "When a server you are browsing goes offline, an orange banner appears"
                + " at the top of the content area with a Retry now button. Other servers"
                + " and your local library continue to work normally."
        ),
        Topic(
            title: "Browsing",
            body: "Each server contributes its own sidebar section listing only the buckets"
                + " it advertises: Albums, Artists, Genres, Years, Random, Recently Added,"
                + " Recently Played, Most Played, Starred, Playlists, Podcasts, Radio."
                + " New buckets appear automatically when the server's capabilities change."
        ),
        Topic(
            title: "Federated search",
            body: "Press ⌘F and start typing. Bòcan queries every connected server in parallel"
                + " alongside your local library and groups the results by source."
        ),
        Topic(
            title: "Stars and ratings",
            body: "Starring a track or setting a 1–5 star rating writes back to the server"
                + " via the standard Subsonic star and setRating calls. Changes appear on the"
                + " server immediately and survive a relaunch."
        ),
        Topic(
            title: "Streaming and scrobbling",
            body: "Tracks stream through the same gapless audio engine as local files,"
                + " with HTTP range requests for accurate seeking."
                + " Scrobbles are sent both to the server's own scrobble endpoint and to your"
                + " configured Last.fm, Musicbrainz, or Rocksky accounts."
        ),
        Topic(
            title: "Jump shortcuts",
            body: "⌘⇧1 through ⌘⇧9 jump straight to the first nine source servers in the order"
                + " they appear in Settings → Sources."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Subsonic Servers")
            Text(
                "Bòcan treats Subsonic-compatible servers (including Navidrome and Airsonic)"
                    + " as first-class sources alongside your local library."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            ForEach(Self.topics, id: \.title) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(.headline)
                    Text(topic.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
