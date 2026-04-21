import Library
import Persistence
import SwiftUI

// MARK: - PlaylistDetailView

/// Main content for a selected playlist.  Shows the header, an ordered
/// list of tracks, reorder and delete affordances.
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

            if self.vm.tracks.isEmpty {
                EmptyState(
                    symbol: "music.note.list",
                    title: "Empty Playlist",
                    message: "Drag tracks here, or use \"Add to Playlist\" from the Songs view."
                )
            } else {
                self.trackList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.PlaylistDetail.view)
        .task(id: self.playlistID) { await self.vm.load(playlistID: self.playlistID) }
    }

    // MARK: - Track list

    private var trackList: some View {
        List(selection: self.$vm.selection) {
            ForEach(self.vm.tracks, id: \.id) { track in
                HStack {
                    Text(track.title ?? URL(fileURLWithPath: track.fileURL).lastPathComponent)
                        .font(Typography.body)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.formatDuration(track.duration))
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.vertical, 2)
                .tag(track.id)
            }
            .onMove { source, destination in
                Task { await self.vm.move(from: source, to: destination) }
            }
            .onDelete { offsets in
                Task { await self.vm.remove(at: offsets) }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand { Task { await self.vm.removeSelected() } }
        .accessibilityIdentifier(A11y.PlaylistDetail.list)
    }

    // MARK: - Actions

    private func playAll() async {
        await self.library.play(tracks: self.vm.tracks, startingAt: 0)
    }

    private func playShuffled() async {
        guard !self.vm.tracks.isEmpty else { return }
        await self.library.setShuffle(true)
        await self.library.play(tracks: self.vm.tracks, startingAt: 0)
    }

    private var accentColour: Color? {
        guard let hex = self.vm.playlist?.accentColor else { return nil }
        return Color(hex: hex)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
