import Persistence
import SwiftUI

// MARK: - GenresView

/// Lists all genres in the library.  Selecting a genre pushes a track list.
public struct GenresView: View {
    public var library: LibraryViewModel

    @State private var genres: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    @State private var isLoading = true

    public init(library: LibraryViewModel) {
        self.library = library
    }

    public var body: some View {
        Group {
            if self.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.genres.isEmpty {
                EmptyState(
                    symbol: "tag",
                    title: "No Genres",
                    message: "No genre tags found in your library."
                )
            } else {
                self.genreList
            }
        }
        .navigationTitle("Genres")
        .task {
            let repo = TrackRepository(database: self.library.database)
            async let genresFetch = try? repo.allGenres()
            async let countsFetch = try? repo.genreTrackCounts()
            self.genres = await genresFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.isLoading = false
        }
    }

    private var genreList: some View {
        List(self.genres, id: \.self) { genre in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "tag.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(genre)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let count = self.trackCounts[genre], count > 0 {
                        Text(count == 1 ? "1 song" : "\(count) songs")
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
                Task { await self.library.selectDestination(.genre(genre)) }
            }
            .accessibilityLabel(genre)
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - ComposersView

/// Lists all composers in the library.  Selecting one pushes a track list.
public struct ComposersView: View {
    public var library: LibraryViewModel

    @State private var composers: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    @State private var isLoading = true

    public init(library: LibraryViewModel) {
        self.library = library
    }

    public var body: some View {
        Group {
            if self.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.composers.isEmpty {
                EmptyState(
                    symbol: "music.note.list",
                    title: "No Composers",
                    message: "No composer tags found in your library."
                )
            } else {
                self.composerList
            }
        }
        .navigationTitle("Composers")
        .task {
            let repo = TrackRepository(database: self.library.database)
            async let composersFetch = try? repo.allComposers()
            async let countsFetch = try? repo.composerTrackCounts()
            self.composers = await composersFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.isLoading = false
        }
    }

    private var composerList: some View {
        List(self.composers, id: \.self) { composer in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(composer)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let count = self.trackCounts[composer], count > 0 {
                        Text(count == 1 ? "1 song" : "\(count) songs")
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
                Task { await self.library.selectDestination(.composer(composer)) }
            }
            .accessibilityLabel(composer)
            .accessibilityAddTraits(.isButton)
        }
    }
}
