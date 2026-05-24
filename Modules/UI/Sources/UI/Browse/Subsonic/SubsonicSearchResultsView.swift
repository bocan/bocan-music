import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSearchResultsPanel

/// Top-of-content panel that surfaces federated Subsonic search results
/// alongside the locally filtered list (Phase 19 step 13).
///
/// Hidden when ``FederatedSearchViewModel/sections`` is empty so it never
/// steals chrome when the user has no servers in global search.
public struct SubsonicSearchResultsPanel: View {
    @ObservedObject public var vm: FederatedSearchViewModel
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @State private var collapsed = false

    public init(
        vm: FederatedSearchViewModel,
        library: LibraryViewModel,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.vm = vm
        self.library = library
        self.coverArtProvider = coverArtProvider
    }

    public var body: some View {
        if self.vm.sections.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                self.header
                if !self.collapsed {
                    Divider()
                    ScrollView(.vertical) {
                        VStack(spacing: 8) {
                            ForEach(self.vm.sections) { section in
                                SubsonicSearchResultsCard(
                                    section: section,
                                    serverID: section.serverID,
                                    library: self.library,
                                    coverArtProvider: self.coverArtProvider
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 360)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle")
                .foregroundStyle(Color.textSecondary)
            Text("Sources")
                .font(Typography.subheadline.weight(.semibold))
            Text("\(self.vm.sections.count) server\(self.vm.sections.count == 1 ? "" : "s")")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { self.collapsed.toggle() }
            } label: {
                Image(systemName: self.collapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.plain)
            .help(self.collapsed ? "Show source results" : "Hide source results")
            .accessibilityLabel(self.collapsed ? "Expand source results" : "Collapse source results")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - SubsonicSearchResultsCard

/// Per-server collapsible card with top artist/album/song matches.
public struct SubsonicSearchResultsCard: View {
    public let section: SubsonicSearchSection
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @State private var expanded = true

    public init(
        section: SubsonicSearchSection,
        serverID: UUID,
        library: LibraryViewModel,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.section = section
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            if self.expanded {
                Divider()
                self.content
                    .padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { self.expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                self.statusIcon
                Text(self.section.serverName)
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                self.statusSummary
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Image(systemName: self.expanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(Color.textSecondary)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch self.section.state {
        case .loading:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Color.orange)
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        switch self.section.state {
        case .loading:
            Text("Searching…")
        case let .success(result):
            let counts = [
                result.artist?.count ?? 0,
                result.album?.count ?? 0,
                result.song?.count ?? 0,
            ]
            let total = counts.reduce(0, +)
            Text("\(total) result\(total == 1 ? "" : "s")")
        case let .failure(msg):
            Text(msg).lineLimit(1)
        case .timedOut:
            Text("Timed out")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.section.state {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Searching this server…")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .success(result):
            self.results(result)

        case let .failure(msg):
            Text(msg)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .timedOut:
            Text("This server didn't respond in time.")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func results(_ result: SearchResult3) -> some View {
        let artists = result.artist ?? []
        let albums = result.album ?? []
        let songs = result.song ?? []

        if artists.isEmpty, albums.isEmpty, songs.isEmpty {
            Text("No matches on this server.")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !artists.isEmpty {
                    self.artistsList(artists)
                }
                if !albums.isEmpty {
                    self.albumsList(albums)
                }
                if !songs.isEmpty {
                    self.songsList(songs)
                }
            }
        }
    }

    private func artistsList(_ artists: [ArtistID3]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Artists")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            ForEach(artists, id: \.id) { artist in
                Button {
                    self.library.selectedDestination = .subsonicArtists(self.serverID)
                } label: {
                    HStack {
                        Image(systemName: "music.mic")
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 18)
                        Text(artist.name)
                            .font(Typography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func albumsList(_ albums: [AlbumID3]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Albums")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            ForEach(albums, id: \.id) { album in
                HStack(spacing: 8) {
                    SubsonicCoverImage(
                        provider: self.coverArtProvider,
                        serverID: self.serverID,
                        entityID: album.coverArt,
                        seed: abs(album.id.hashValue),
                        pixelSize: 64
                    )
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(album.name)
                            .font(Typography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if let artist = album.artist, !artist.isEmpty {
                            Text(artist)
                                .font(Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func songsList(_ songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Songs")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SubsonicSongRow(
                    song: song,
                    serverID: self.serverID,
                    coverArtProvider: self.coverArtProvider
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task {
                        await self.library.play(
                            subsonicSongs: songs,
                            serverID: self.serverID,
                            startingAt: index
                        )
                    }
                }
                .contextMenu {
                    Button("Play") {
                        Task {
                            await self.library.play(
                                subsonicSongs: songs,
                                serverID: self.serverID,
                                startingAt: index
                            )
                        }
                    }
                }
            }
        }
    }
}
