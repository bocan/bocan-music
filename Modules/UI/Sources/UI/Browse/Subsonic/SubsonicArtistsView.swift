import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicArtistsView

/// Per-server Artists destination (Phase 19 step 10).
///
/// The list is rendered as one `Section` per index bucket returned by
/// `getArtists`. No paging — Subsonic returns the full index in one call.
public struct SubsonicArtistsView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicArtistsViewModel

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
            wrappedValue: SubsonicArtistsViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.sections.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.mic",
                    description: Text("This server hasn't returned any artists yet.")
                )
            } else {
                List {
                    ForEach(self.vm.sections, id: \.name) { section in
                        Section(section.name) {
                            ForEach(section.artist) { artist in
                                SubsonicArtistRow(
                                    artist: artist,
                                    serverID: self.serverID,
                                    coverArtProvider: self.coverArtProvider
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Artists")
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
            if self.vm.sections.isEmpty { await self.vm.load() }
        }
        .alert(
            "Couldn't load artists",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }
}

// MARK: - SubsonicArtistRow

private struct SubsonicArtistRow: View {
    let artist: ArtistID3
    let serverID: UUID
    let coverArtProvider: SubsonicCoverArtProvider?

    var body: some View {
        HStack(spacing: 10) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: self.artist.coverArt,
                seed: abs(self.artist.id.hashValue),
                pixelSize: 64
            )
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(self.artist.name)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let count = self.artist.albumCount, count > 0 {
                    Text(count == 1 ? "1 album" : "\(count) albums")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.artist.name)
    }
}
