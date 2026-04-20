import Persistence
import SwiftUI

// MARK: - SearchResultsView

/// Shows grouped FTS results: Tracks, Albums, Artists.
///
/// Each group has a header and a collapsed list of rows.  Selecting a result
/// navigates to its detail view via `LibraryViewModel`.
public struct SearchResultsView: View {
    @ObservedObject public var vm: SearchViewModel
    public var library: LibraryViewModel

    public init(vm: SearchViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        Group {
            if self.vm.isSearching {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.results.isEmpty, !self.vm.query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: "No Results",
                    message: "Nothing matched \"\(self.vm.query)\". Try a different search."
                )
            } else if self.vm.query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: "Search Your Library",
                    message: "Type to find songs, albums, and artists."
                )
            } else {
                self.resultsList
            }
        }
        .navigationTitle("Search")
        .accessibilityIdentifier(A11y.SearchResults.results)
    }

    // MARK: - Results list

    private var resultsList: some View {
        List {
            if !self.vm.results.tracks.isEmpty {
                Section {
                    ForEach(self.vm.results.tracks, id: \.track.id) { hit in
                        self.trackRow(hit)
                    }
                } header: {
                    self.sectionHeader("Songs", count: self.vm.results.tracks.count)
                }
            }

            if !self.vm.results.albums.isEmpty {
                Section {
                    ForEach(self.vm.results.albums, id: \.id) { album in
                        self.albumRow(album)
                    }
                } header: {
                    self.sectionHeader("Albums", count: self.vm.results.albums.count)
                }
            }

            if !self.vm.results.artists.isEmpty {
                Section {
                    ForEach(self.vm.results.artists, id: \.id) { artist in
                        self.artistRow(artist)
                    }
                } header: {
                    self.sectionHeader("Artists", count: self.vm.results.artists.count)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Row helpers

    private func trackRow(_ hit: TrackSearchHit) -> some View {
        let track = hit.track
        return HStack(spacing: 8) {
            Artwork(artPath: hit.coverArtPath, seed: Int(track.id ?? 0), size: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? "Unknown")
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let artist = hit.artistName {
                    Text(artist)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(Formatters.duration(track.duration))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await self.library.play(track: track) }
        }
        .accessibilityLabel("\(track.title ?? "Unknown"), \(hit.artistName ?? ""), \(Formatters.duration(track.duration))")
        .accessibilityAddTraits(.isButton)
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 8) {
            if let path = album.coverArtPath {
                Artwork(artPath: path, seed: Int(album.id ?? 0), size: 32)
                    .accessibilityHidden(true)
            } else {
                GradientPlaceholder(seed: Int(album.id ?? 0))
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let year = album.year {
                    Text("\(year)")
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
        .onTapGesture {
            if let id = album.id {
                Task { await self.library.selectDestination(.album(id)) }
            }
        }
        .accessibilityLabel(album.title)
        .accessibilityAddTraits(.isButton)
    }

    private func artistRow(_ artist: Artist) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.mic")
                .font(.system(size: 20))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            Text(artist.name)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = artist.id {
                Task { await self.library.selectDestination(.artist(id)) }
            }
        }
        .accessibilityLabel(artist.name)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(count)")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }
}
