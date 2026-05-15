import SwiftUI

// MARK: - HelpWindowView

/// In-app help reference shown from Help → Bòcan Music Help.
struct HelpWindowView: View {
    // MARK: - HelpSection

    private enum HelpSection: String, CaseIterable, Hashable {
        case gettingStarted = "Getting Started"
        case shortcuts = "Keyboard Shortcuts"
        case formats = "Supported Formats"

        var icon: String {
            switch self {
            case .gettingStarted:
                "questionmark.circle"

            case .shortcuts:
                "keyboard"

            case .formats:
                "music.note.list"
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

            case .formats:
                FormatsSection()
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
            body: "Create standard playlists with File → New Playlist… (⌘N)"
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
            body: "Connect your Last.fm account under Bòcan → Settings… → Scrobbling"
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

    private static let shortcuts: [Shortcut] = [
        Shortcut(action: "Play / Pause", key: "Space"),
        Shortcut(action: "Next Track", key: "⌘→"),
        Shortcut(action: "Previous Track", key: "⌘←"),
        Shortcut(action: "Toggle Shuffle", key: "⌘S"),
        Shortcut(action: "Cycle Repeat", key: "⌘R"),
        Shortcut(action: "Get Info", key: "⌘I"),
        Shortcut(action: "Find", key: "⌘F"),
        Shortcut(action: "New Playlist", key: "⌘N"),
        Shortcut(action: "Add Folder to Library", key: "⌘⇧O"),
        Shortcut(action: "Reveal in Finder", key: "⌘⌥R"),
        Shortcut(action: "Show Lyrics", key: "⌘⌥L"),
        Shortcut(action: "Toggle Miniplayer", key: "⌘⌥M"),
        Shortcut(action: "Show Up Next", key: "⌘⌥U"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            helpSectionTitle("Keyboard Shortcuts")
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                GridRow {
                    Text("Action")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("Shortcut")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                Divider()
                    .padding(.bottom, 8)
                ForEach(Self.shortcuts, id: \.action) { shortcut in
                    GridRow {
                        Text(shortcut.action)
                        Text(shortcut.key)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
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
                    formats: "OGG Vorbis / Speex / Ogg FLAC, Opus, MP2/MP1, AC-3, DTS, WMA, Wave64, RF64, Matroska/MKV/WebM, AU/SND, APE (Monkey's Audio), WavPack, DSD (DSF/DFF)"
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
