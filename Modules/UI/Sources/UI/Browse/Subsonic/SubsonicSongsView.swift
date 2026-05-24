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

    @StateObject private var vm: SubsonicSongsViewModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
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
        .navigationTitle("Songs")
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

            Text(Self.formatDuration(self.song.duration))
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func formatDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
