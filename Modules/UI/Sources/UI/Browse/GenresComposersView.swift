import Persistence
import SwiftUI

// MARK: - GenresView

/// Lists all genres in the library.  Selecting a genre pushes a track list.
public struct GenresView: View {
    public var library: LibraryViewModel

    @State private var genres: [String] = []
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
            do {
                self.genres = try await TrackRepository(database: self.library.database).allGenres()
            } catch {}
            self.isLoading = false
        }
    }

    private var genreList: some View {
        List(self.genres, id: \.self) { genre in
            HStack {
                Label(genre, systemImage: "tag")
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)

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
            do {
                self.composers = try await TrackRepository(database: self.library.database).allComposers()
            } catch {}
            self.isLoading = false
        }
    }

    private var composerList: some View {
        List(self.composers, id: \.self) { composer in
            HStack {
                Label(composer, systemImage: "music.note.list")
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)

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
