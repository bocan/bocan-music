import Persistence
import SwiftUI

// MARK: - AlbumCell

/// A single album cell in the grid: cover art + title + artist name + track count.
private struct AlbumCell: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Artwork
            if let path = album.coverArtPath {
                Artwork(artPath: path, seed: Int(self.album.id ?? 0), size: Theme.albumGridMinWidth)
                    .accessibilityLabel("\(self.album.title) artwork")
            } else {
                GradientPlaceholder(seed: Int(self.album.id ?? 0))
                    .frame(width: Theme.albumGridMinWidth, height: Theme.albumGridMinWidth)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                    .accessibilityLabel("\(self.album.title) artwork placeholder")
            }

            // Title
            Text(self.album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            // Year
            if let year = album.year {
                Text("\(year)")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(width: Theme.albumGridMinWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.album.title), \(self.album.year.map { "\($0)" } ?? "")")
    }
}

// MARK: - AlbumsGridView

/// Adaptive `LazyVGrid` of album cells.
///
/// Clicking an album pushes `AlbumDetailView` by setting `vm.selectedAlbumID`.
public struct AlbumsGridView: View {
    @ObservedObject public var vm: AlbumsViewModel
    public var library: LibraryViewModel

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
                EmptyState(
                    symbol: "square.grid.2x2",
                    title: "No Albums",
                    message: "Your library doesn't contain any albums yet."
                )
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
                    AlbumCell(album: album)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let id = album.id {
                                self.vm.selectedAlbumID = id
                            }
                        }
                        .contextMenu {
                            Button("Play Album") {
                                Task {
                                    if let id = album.id {
                                        await self.library.selectDestination(.album(id))
                                    }
                                }
                            }
                            Divider()
                            Toggle("Force Gapless Playback", isOn: Binding(
                                get: { album.forceGapless },
                                set: { forced in
                                    if let id = album.id {
                                        Task { await self.library.setAlbumForceGapless(albumID: id, forced: forced) }
                                    }
                                }
                            ))
                            Divider()
                            Button("Get Info") {}.disabled(true) // TODO(phase-8)
                        }
                }
            }
            .padding(Theme.albumGridSpacing)
        }
        .navigationDestination(for: Int64.self) { albumID in
            AlbumDetailView(albumID: albumID, library: self.library)
        }
        .accessibilityIdentifier(A11y.AlbumsGrid.grid)
        // Navigate to selected album
        .onChange(of: self.vm.selectedAlbumID) { _, newID in
            if let id = newID {
                Task { await self.library.selectDestination(.album(id)) }
            }
        }
    }
}
