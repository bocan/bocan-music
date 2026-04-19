import AppKit
import Foundation
import Observability
import Persistence
import SwiftUI

// MARK: - Context menu helper types

/// Actions that context menus can trigger.
///
/// Phase 6, 8 stubs are marked `TODO(phase-NN)` and perform no-ops until
/// wired by the respective phase.
public struct TrackActions {
    /// Play a single track immediately.
    public var playNow: @MainActor (Track) async -> Void

    /// Enqueue tracks to play immediately after the current item.
    public var playNext: @MainActor ([Track]) -> Void

    /// Append tracks to the end of the queue.
    public var addToQueue: @MainActor ([Track]) -> Void

    /// Play all tracks from the album of the given track.
    public var playAlbum: @MainActor (Track) -> Void

    /// Shuffle all tracks from the album of the given track.
    public var shuffleAlbum: @MainActor (Track) -> Void

    /// Play all tracks by the artist of the given track.
    public var playArtist: @MainActor (Track) -> Void

    /// TODO(phase-6): Add to playlist.
    public var addToPlaylist: @MainActor ([Track]) -> Void

    /// Toggle the `loved` flag on a track.
    public var toggleLoved: @MainActor (Track) async -> Void

    /// Set rating 0–5 stars (stored as 0–100).
    public var setRating: @MainActor (Track, Int) async -> Void

    /// Reveal the backing file in Finder.
    public var revealInFinder: @MainActor (Track) -> Void

    /// TODO(phase-8): Open the tag editor.
    public var getInfo: @MainActor ([Track]) -> Void

    /// Copy track metadata as TSV to the pasteboard.
    public var copy: @MainActor ([Track]) -> Void

    /// Creates a new ``TrackActions`` with the provided action closures.
    public init(
        playNow: @escaping @MainActor (Track) async -> Void,
        playNext: @escaping @MainActor ([Track]) -> Void = { _ in },
        addToQueue: @escaping @MainActor ([Track]) -> Void = { _ in },
        playAlbum: @escaping @MainActor (Track) -> Void = { _ in },
        shuffleAlbum: @escaping @MainActor (Track) -> Void = { _ in },
        playArtist: @escaping @MainActor (Track) -> Void = { _ in },
        addToPlaylist: @escaping @MainActor ([Track]) -> Void = { _ in },
        toggleLoved: @escaping @MainActor (Track) async -> Void,
        setRating: @escaping @MainActor (Track, Int) async -> Void,
        revealInFinder: @escaping @MainActor (Track) -> Void,
        getInfo: @escaping @MainActor ([Track]) -> Void = { _ in },
        copy: @escaping @MainActor ([Track]) -> Void
    ) {
        self.playNow = playNow
        self.playNext = playNext
        self.addToQueue = addToQueue
        self.playAlbum = playAlbum
        self.shuffleAlbum = shuffleAlbum
        self.playArtist = playArtist
        self.addToPlaylist = addToPlaylist
        self.toggleLoved = toggleLoved
        self.setRating = setRating
        self.revealInFinder = revealInFinder
        self.getInfo = getInfo
        self.copy = copy
    }
}

// MARK: - Context menu builder

/// Builds the standard right-click context menu for track selections.
public struct TrackContextMenu: View {
    private let tracks: [Track]
    private let actions: TrackActions
    private let log = AppLogger.make(.ui)

    public init(tracks: [Track], actions: TrackActions) {
        self.tracks = tracks
        self.actions = actions
    }

    public var body: some View {
        let track = self.tracks.first

        // Play Now — single selection only
        if let track {
            Button("Play Now") {
                Task { @MainActor in await self.actions.playNow(track) }
            }
            Divider()
        }

        Button("Play Next") {
            self.actions.playNext(self.tracks)
        }
        .disabled(self.tracks.isEmpty)

        Button("Add to Queue") {
            self.actions.addToQueue(self.tracks)
        }
        .disabled(self.tracks.isEmpty)

        if let track {
            Button("Play Album") {
                self.actions.playAlbum(track)
            }
            Button("Shuffle Album") {
                self.actions.shuffleAlbum(track)
            }
            Button("Play Artist") {
                self.actions.playArtist(track)
            }
        }

        // Phase 6 stub
        Menu("Add to Playlist") {
            Text("No playlists yet")
                .foregroundStyle(.secondary)
        }
        .disabled(true) // TODO(phase-6): enable when Playlist module lands

        Divider()

        if let track {
            Button(track.loved ? "Unlove" : "Love") {
                Task { @MainActor in await self.actions.toggleLoved(track) }
            }
            .keyboardShortcut("l", modifiers: .command)

            Menu("Rate") {
                ForEach(0 ... 5, id: \.self) { star in
                    Button(self.starLabel(star)) {
                        Task { @MainActor in await self.actions.setRating(track, star) }
                    }
                    .keyboardShortcut(
                        star > 0 ? KeyEquivalent(Character("\(star)")) : KeyEquivalent("0"),
                        modifiers: .command
                    )
                }
            }
        }

        Divider()

        if let track {
            Button("Show in Finder") {
                self.actions.revealInFinder(track)
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        Button("Get Info") {
            self.actions.getInfo(self.tracks)
        }
        .disabled(true) // TODO(phase-8): enable when tag editor lands
        .keyboardShortcut("i", modifiers: .command)

        Divider()

        Button("Copy") {
            self.actions.copy(self.tracks)
        }
        .keyboardShortcut("c", modifiers: .command)
    }

    // MARK: - Helpers

    private func starLabel(_ stars: Int) -> String {
        stars == 0 ? "None" : String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
    }
}

// MARK: - Finder reveal helper

extension Track {
    /// Reveals this track's backing file in Finder using a security-scoped URL.
    @MainActor
    func revealInFinder() {
        guard let url = URL(string: fileURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - TSV copy helper

extension [Track] {
    /// Copies the selection as a tab-separated block of track metadata.
    @MainActor
    func copyAsTSV() {
        let header = "Title\tArtist\tAlbum\tYear\tGenre\tDuration\tRating"
        let rows = map { t in
            [
                t.title ?? "",
                "", // artist name needs join — caller resolves
                "", // album name needs join — caller resolves
                t.year.map(String.init) ?? "",
                t.genre ?? "",
                Formatters.duration(t.duration),
                String(Formatters.stars(from: t.rating)),
            ].joined(separator: "\t")
        }
        let tsv = ([header] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
    }
}
