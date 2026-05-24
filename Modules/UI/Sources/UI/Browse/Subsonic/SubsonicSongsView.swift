import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSongsView

/// Per-server Songs destination (Phase 19 step 10).
///
/// Subsonic has no global "all songs" endpoint, so this view presents a
/// shuffled sample fetched via `getRandomSongs`. The toolbar offers a
/// Refresh action to reseed the sample and the list lazy-loads further
/// pages as the user scrolls.
public struct SubsonicSongsView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?
    public let title: String

    @StateObject private var vm: SubsonicSongsViewModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?,
        title: String = "Songs"
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.title = title
        self._vm = StateObject(
            wrappedValue: SubsonicSongsViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.songs.isEmpty, !self.vm.isLoading {
                self.emptyState
            } else {
                self.list
            }
        }
        .navigationTitle(self.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await self.vm.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty { await self.vm.load() }
        }
        .alert(
            "Couldn't load songs",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if self.vm.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Songs",
                systemImage: "music.note",
                description: Text("This server hasn't returned any songs yet.")
            )
        }
    }

    private var list: some View {
        List {
            ForEach(Array(self.vm.songs.enumerated()), id: \.element.id) { index, song in
                SubsonicSongRow(
                    song: song,
                    serverID: self.serverID,
                    coverArtProvider: self.coverArtProvider
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task {
                        await self.library.play(
                            subsonicSongs: self.vm.songs,
                            serverID: self.serverID,
                            startingAt: index
                        )
                    }
                }
                .contextMenu {
                    Button("Play") {
                        Task {
                            await self.library.play(
                                subsonicSongs: self.vm.songs,
                                serverID: self.serverID,
                                startingAt: index
                            )
                        }
                    }
                }
                .onAppear {
                    if index >= self.vm.songs.count - 10, self.vm.hasMorePages {
                        Task { await self.vm.loadMore() }
                    }
                }
            }

            if self.vm.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - SubsonicSongRow

struct SubsonicSongRow: View {
    let song: Song
    let serverID: UUID
    let coverArtProvider: SubsonicCoverArtProvider?

    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator

    var body: some View {
        HStack(spacing: 10) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: self.song.coverArt,
                seed: abs(self.song.id.hashValue),
                pixelSize: 80
            )
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.song.title)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                let subtitle = [self.song.artist, self.song.album]
                    .compactMap(\.self)
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let coord = self.annotationCoordinator {
                SubsonicStarButton(song: self.song, serverID: self.serverID, coordinator: coord)
            }

            Text(Self.formatDuration(self.song.duration))
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let coord = self.annotationCoordinator {
                SubsonicRatingMenu(song: self.song, serverID: self.serverID, coordinator: coord)
            }
        }
    }

    static func formatDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - SubsonicStarButton

struct SubsonicStarButton: View {
    let song: Song
    let serverID: UUID
    @ObservedObject var coordinator: SubsonicAnnotationCoordinator

    var body: some View {
        let starred = self.coordinator.isStarred(songID: self.song.id, serverStarred: self.song.starred)
        Button {
            self.coordinator.toggleStar(
                songID: self.song.id,
                serverID: self.serverID,
                currentlyStarred: starred
            )
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? Color.yellow : Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help(starred ? "Unstar" : "Star")
        .accessibilityLabel(starred ? "Unstar \(self.song.title)" : "Star \(self.song.title)")
    }
}

// MARK: - SubsonicRatingMenu

struct SubsonicRatingMenu: View {
    let song: Song
    let serverID: UUID
    @ObservedObject var coordinator: SubsonicAnnotationCoordinator

    var body: some View {
        let current = self.coordinator.rating(songID: self.song.id, serverRating: self.song.userRating)
        Menu("Rating") {
            ForEach(0 ... 5, id: \.self) { stars in
                Button {
                    self.coordinator.setRating(
                        songID: self.song.id,
                        serverID: self.serverID,
                        newRating: stars,
                        previousRating: self.song.userRating
                    )
                } label: {
                    HStack {
                        Text(stars == 0 ? "None" : String(repeating: "★", count: stars))
                        if stars == current { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }
}
