import Persistence
import SwiftUI

// MARK: - AlbumCell

/// A single album cell in the grid: cover art + title + artist name + track count.
private struct AlbumCell: View {
    let album: Album
    let artistName: String?
    let trackCount: Int?

    var body: some View {
        let displayArtist = self.artistName ?? "Various Artists"
        VStack(alignment: .leading, spacing: 4) {
            // Artwork — always a 1:1 square that fills the grid cell's width.
            // `Artwork` self-applies an aspect-ratio constraint so the loaded
            // image and the gradient placeholder lay out identically.
            Group {
                if let path = album.coverArtPath {
                    Artwork(artPath: path, seed: Int(self.album.id ?? 0), size: Theme.albumGridMinWidth)
                        .accessibilityLabel("\(self.album.title) artwork")
                } else {
                    GradientPlaceholder(seed: Int(self.album.id ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityLabel("\(self.album.title) artwork placeholder")
                }
            }
            .frame(maxWidth: .infinity)

            // Title
            Text(self.album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            // Artist name (or "Various Artists" when no album artist is set)
            Text(displayArtist)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            // Year · track count
            let yearString = self.album.year.map { String($0) }
            let countString = self.trackCount.map { "\($0) \($0 == 1 ? "song" : "songs")" }
            let subtitle = [yearString, countString].compactMap(\.self).joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.album.title), \(displayArtist)")
    }
}

// MARK: - AlbumsGridView

/// Adaptive `LazyVGrid` of album cells.
///
/// Clicking an album pushes `AlbumDetailView` by setting `vm.selectedAlbumID`.
public struct AlbumsGridView: View {
    @ObservedObject public var vm: AlbumsViewModel
    public var library: LibraryViewModel
    /// Phase 4 audit L3: Cmd-click multi-select for albums.
    @State private var selection: Set<Int64> = []

    public init(vm: AlbumsViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    private let columns = [GridItem(.adaptive(minimum: Theme.albumGridMinWidth), spacing: Theme.albumGridSpacing)]

    public var body: some View {
        Group {
            if self.vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.albums.isEmpty {
                // Phase 4 audit L2: offer the same Add Music Folder action as TracksView.
                EmptyState(
                    symbol: "square.grid.2x2",
                    title: "No Albums",
                    message: "Add a music folder to start building your library.",
                    actionLabel: "Add Music Folder"
                ) {
                    Task { await self.library.addFolderByPicker() }
                }
            } else {
                self.albumGrid
            }
        }
        .navigationTitle("Albums")
    }

    // MARK: - Grid

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                ForEach(self.vm.albums, id: \.id) { album in
                    let artistName = album.albumArtistID.flatMap { self.vm.artistNames[$0] }
                    let trackCount = album.id.flatMap { self.vm.trackCounts[$0] }
                    let isSelected = album.id.map { self.selection.contains($0) } ?? false
                    AlbumCell(album: album, artistName: artistName, trackCount: trackCount)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        // Phase 4 audit L3: Cmd-click toggles into the multi-selection set
                        // without navigating; plain click clears the selection and drills in.
                        .highPriorityGesture(
                            TapGesture().modifiers(.command).onEnded {
                                guard let id = album.id else { return }
                                if self.selection.contains(id) {
                                    self.selection.remove(id)
                                } else {
                                    self.selection.insert(id)
                                }
                            }
                        )
                        .onTapGesture {
                            if let id = album.id {
                                self.selection = []
                                self.vm.selectedAlbumID = id
                            }
                        }
                        .contextMenu {
                            self.albumContextMenu(album: album)
                        }
                }
            }
            .padding(Theme.albumGridSpacing)
        }
        .navigationDestination(for: Int64.self) { albumID in
            AlbumDetailView(albumID: albumID, library: self.library)
        }
        .accessibilityIdentifier(A11y.AlbumsGrid.grid)
        // Navigate to selected album.
        // Reset to nil after each navigation so that tapping the same
        // album a second time always fires (onChange fires on *change* only).
        .onChange(of: self.vm.selectedAlbumID) { _, newID in
            if let id = newID {
                self.vm.selectedAlbumID = nil
                Task { await self.library.selectDestination(.album(id)) }
            }
        }
    }

    // MARK: - Context menu

    /// The set of album IDs the right-click affects: either the multi-selection
    /// (when the right-clicked album is part of it) or just this single album.
    private func targetIDs(for album: Album) -> [Int64] {
        guard let id = album.id else { return [] }
        if self.selection.contains(id), self.selection.count > 1 {
            return Array(self.selection)
        }
        return [id]
    }

    @ViewBuilder
    private func albumContextMenu(album: Album) -> some View {
        let ids = self.targetIDs(for: album)
        let multi = ids.count > 1

        Button(multi ? "Play \(ids.count) Albums" : "Play Album") {
            Task {
                for id in ids {
                    await self.library.selectDestination(.album(id))
                }
            }
        }
        .disabled(ids.isEmpty)

        if !multi {
            Divider()
            Toggle("Force Gapless Playback", isOn: Binding(
                get: { album.forceGapless },
                set: { forced in
                    if let id = album.id {
                        Task { await self.library.setAlbumForceGapless(albumID: id, forced: forced) }
                    }
                }
            ))
            Toggle("Exclude from Shuffle", isOn: Binding(
                get: { album.excludedFromShuffle },
                set: { excluded in
                    if let id = album.id {
                        Task { await self.library.setAlbumExcludedFromShuffle(albumID: id, excluded: excluded) }
                    }
                }
            ))
        }

        Divider()
        // Phase 4 audit L8: wire Get Info now that Phase 8 has shipped.
        Button(multi ? "Get Info (\(ids.count) Albums)" : "Get Info") {
            Task { await self.openInspector(forAlbumIDs: ids) }
        }
        .disabled(ids.isEmpty)
    }

    /// Loads every track for the given album IDs and opens the track inspector.
    private func openInspector(forAlbumIDs ids: [Int64]) async {
        let repo = TrackRepository(database: self.library.database)
        var collected: [Track] = []
        for id in ids {
            if let tracks = try? await repo.fetchAll(albumID: id) {
                collected.append(contentsOf: tracks)
            }
        }
        await MainActor.run {
            self.library.showInspector(tracks: collected)
        }
    }
}
