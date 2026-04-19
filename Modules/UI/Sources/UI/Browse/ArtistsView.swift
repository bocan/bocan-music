import Persistence
import SwiftUI

// MARK: - ArtistDetailView

/// Album grid for a single artist + drilldown to tracks.
public struct ArtistDetailView: View {
    public let artistID: Int64
    public var library: LibraryViewModel

    @State private var artist: Artist?
    @State private var albumCount = 0
    @State private var trackCount = 0

    public init(artistID: Int64, library: LibraryViewModel) {
        self.artistID = artistID
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Artist header
            if let artist {
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
                            if self.albumCount > 0 {
                                Text(self.albumCount == 1 ? "1 album" : "\(self.albumCount) albums")
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            if self.albumCount > 0, self.trackCount > 0 {
                                Text("·")
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textTertiary)
                            }
                            if self.trackCount > 0 {
                                Text(self.trackCount == 1 ? "1 song" : "\(self.trackCount) songs")
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(20)
                .background(Color.bgSecondary)

                Divider()
            }

            // Albums by this artist
            AlbumsGridView(vm: self.library.albums, library: self.library)
        }
        .task {
            await self.load()
        }
    }

    private func load() async {
        await self.library.albums.load(albumArtistID: self.artistID)
        self.albumCount = self.library.albums.albums.count
        if let artist = try? await ArtistRepository(database: library.database).fetch(id: artistID) {
            self.artist = artist
        }
        // Count tracks for this artist
        let trackRepo = TrackRepository(database: library.database)
        if let tracks = try? await trackRepo.fetchAll(artistID: self.artistID) {
            self.trackCount = tracks.count
        }
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
        .onChange(of: self.vm.selectedArtistID) { _, id in
            if let id {
                Task { await self.library.selectDestination(.artist(id)) }
            }
        }
    }
}
