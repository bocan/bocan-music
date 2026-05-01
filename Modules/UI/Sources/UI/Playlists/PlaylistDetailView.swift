import Library
import Persistence
import SwiftUI

// MARK: - PlaylistDetailView

/// Main content for a selected playlist.  Shows the header, an ordered
/// list of tracks using the shared TracksView component, and a drop target
/// for adding tracks by drag-and-drop.
public struct PlaylistDetailView: View {
    @StateObject private var vm: PlaylistDetailViewModel
    @ObservedObject public var library: LibraryViewModel
    public let playlistID: Int64

    public init(playlistID: Int64, library: LibraryViewModel, service: PlaylistService) {
        self.playlistID = playlistID
        self.library = library
        self._vm = StateObject(
            wrappedValue: PlaylistDetailViewModel(service: service, database: library.database)
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            PlaylistHeader(
                title: self.vm.title,
                trackCount: self.vm.trackCount,
                duration: self.vm.totalDuration,
                accent: self.accentColour,
                playAction: { Task { await self.playAll() } },
                shuffleAction: { Task { await self.playShuffled() } }
            )

            Group {
                if self.vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if self.vm.tracks.isEmpty {
                    EmptyState(
                        symbol: "music.note.list",
                        title: "Empty Playlist",
                        message: "Drag tracks here, or use \"Add to Playlist\" from the Songs view."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TracksView(
                        vm: self.library.tracks,
                        library: self.library,
                        sortable: false,
                        removeFromPlaylist: { [weak vm] tracks in
                            guard let vm else { return }
                            var offsets = IndexSet()
                            for (idx, t) in vm.tracks.enumerated()
                                where tracks.contains(where: { $0.id == t.id && $0.id != nil }) {
                                offsets.insert(idx)
                            }
                            guard !offsets.isEmpty else { return }
                            Task { await vm.remove(at: offsets) }
                        },
                        onMove: self.vm.playlist?.kind == .manual
                            ? { [weak vm] source, destination in
                                guard let vm else { return }
                                Task { await vm.move(from: source, to: destination) }
                            }
                            : nil
                    )
                }
            }
            .overlay(
                TrackDropTarget { ids in
                    Task { await self.vm.addTracks(ids) }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.PlaylistDetail.view)
        .task(id: self.playlistID) {
            await self.vm.load(playlistID: self.playlistID)
            self.library.tracks.setTracks(self.vm.tracks, preserveOrder: true)
        }
        .onChange(of: self.vm.tracks.map(\.id)) { _, _ in
            self.library.tracks.setTracks(self.vm.tracks, preserveOrder: true)
        }
    }

    // MARK: - Actions

    private func playAll() async {
        await self.library.play(tracks: self.vm.tracks, startingAt: 0)
    }

    private func playShuffled() async {
        guard !self.vm.tracks.isEmpty else { return }
        await self.library.play(tracks: self.vm.tracks, startingAt: 0)
        await self.library.setShuffle(true)
    }

    private var accentColour: Color? {
        guard let hex = self.vm.playlist?.accentColor else { return nil }
        return Color(hex: hex)
    }
}
