import Persistence
import SwiftUI

// MARK: - ArtistDetailView

/// Artist header + optional album grid + full-featured track table.
public struct ArtistDetailView: View {
    public let artistID: Int64
    public var library: LibraryViewModel

    @State private var artist: Artist?
    @State private var albums: [Album] = []

    private let albumColumns = [GridItem(.adaptive(minimum: Theme.albumGridMinWidth), spacing: Theme.albumGridSpacing)]

    public init(artistID: Int64, library: LibraryViewModel) {
        self.artistID = artistID
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Artist header
            if let artist {
                self.artistHeader(artist)
                    .padding(20)
                    .background(Color.bgSecondary)
                Divider()
            }

            // Albums section — scrollable, capped so Songs table gets most of the space
            if !self.albums.isEmpty {
                self.sectionLabel("Albums")
                ScrollView {
                    LazyVGrid(columns: self.albumColumns, spacing: Theme.albumGridSpacing) {
                        ForEach(self.albums, id: \.id) { album in
                            self.albumCell(album)
                        }
                    }
                    .padding(Theme.albumGridSpacing)
                }
                .frame(maxHeight: 260)
                Divider()
            }

            // Songs — full TracksView with context menus, drag, columns, sorting
            self.sectionLabel("Songs")
            TracksView(vm: self.library.tracks, library: self.library, sortable: true)
        }
        .task {
            await self.load()
        }
    }

    // MARK: - Sub-views

    private func artistHeader(_ artist: Artist) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "music.mic")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: 8) {
                    if !self.albums.isEmpty {
                        Text(self.albums.count == 1 ? "1 album" : "\(self.albums.count) albums")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    let trackCount = self.library.tracks.rows.count
                    if !self.albums.isEmpty, trackCount > 0 {
                        Text("·")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    if trackCount > 0 {
                        Text(trackCount == 1 ? "1 song" : "\(trackCount) songs")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            Spacer()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Typography.title)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSecondary)
    }

    private func albumCell(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let path = album.coverArtPath {
                    Artwork(artPath: path, seed: Int(album.id ?? 0), size: Theme.albumGridMinWidth)
                        .accessibilityLabel("\(album.title) artwork")
                } else {
                    GradientPlaceholder(seed: Int(album.id ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityLabel("\(album.title) artwork placeholder")
                }
            }
            .frame(maxWidth: .infinity)

            Text(album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            if let year = album.year {
                Text(String(year))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = album.id {
                Task { await self.library.selectDestination(.album(id)) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(album.title)
    }

    // MARK: - Data loading

    private func load() async {
        async let albumsFetch: [Album] = await (try? AlbumRepository(
            database: self.library.database
        ).fetchAll(albumArtistID: self.artistID)) ?? []
        async let artistFetch = try? await ArtistRepository(database: self.library.database).fetch(id: self.artistID)
        // Load tracks via the shared TracksViewModel so TracksView gets full column data,
        // context menus, drag-to-playlist, sorting, and selection for free.
        async let trackLoad: Void = self.library.tracks.load(artistID: self.artistID)

        self.albums = await albumsFetch
        self.artist = await artistFetch
        _ = await trackLoad
    }
}

// MARK: - ArtistsView

/// Sidebar-style list of all artists with count badges.
public struct ArtistsView: View {
    @ObservedObject public var vm: ArtistsViewModel
    public var library: LibraryViewModel

    public init(vm: ArtistsViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        Group {
            if self.vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.artists.isEmpty {
                EmptyState(
                    symbol: "music.mic",
                    title: "No Artists",
                    message: "Your library doesn't contain any artists yet."
                )
            } else {
                self.artistList
            }
        }
        .navigationTitle("Artists")
    }

    private var artistList: some View {
        List(self.vm.artists, id: \.id, selection: self.$vm.selectedArtistID) { artist in
            HStack(spacing: 10) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let id = artist.id, let count = self.vm.albumCounts[id], count > 0 {
                        Text(count == 1 ? "1 album" : "\(count) albums")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(artist.name)
        }
        // Reset to nil so the same artist can be re-selected on the next tap.
        .onChange(of: self.vm.selectedArtistID) { _, id in
            if let id {
                self.vm.selectedArtistID = nil
                Task { await self.library.selectDestination(.artist(id)) }
            }
        }
    }
}
