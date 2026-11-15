import Jellyfin
import SwiftUI

// MARK: - JellyfinArtistsView

/// Per-server Artists destination (ADR-097): album artists in a list grouped by
/// initial, loaded a page at a time. When the search field has text the same
/// list shows the artists found across every Jellyfin server in global search,
/// each row marked with its source.
public struct JellyfinArtistsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinArtistsViewModel
    /// Observed separately, so the view redraws when the search model publishes.
    @ObservedObject private var search: JellyfinMultiSourceSearchViewModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: JellyfinArtistsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.jellyfin.metadataCache
            )
        )
        self.search = library.jellyfin.search
            ?? JellyfinMultiSourceSearchViewModel(dataSource: NoopJellyfinBrowseDataSource())
    }

    private var isSearching: Bool {
        !self.library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        Group {
            if self.isSearching {
                self.searchBody
            } else {
                self.regularBody
            }
        }
        .navigationTitle(L10n.string("Artists"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await self.vm.load() }
                } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading || self.isSearching)
                .help(L10n.string("Fetches this server's artist list again."))
            }
        }
        .task(id: self.serverID) {
            if self.vm.artists.isEmpty {
                await self.vm.load()
            }
        }
        .loadErrorAlert(L10n.string("Couldn't load artists"), message: self.$vm.errorMessage)
    }

    // MARK: Regular mode

    @ViewBuilder
    private var regularBody: some View {
        if self.vm.artists.isEmpty, !self.vm.isLoading {
            ContentUnavailableView(
                L10n.string("No Artists"),
                systemImage: "music.mic",
                description: Text(localized: "This server hasn't returned any artists yet.")
            )
        } else {
            List {
                ForEach(self.vm.sections) { section in
                    Section(section.letter) {
                        ForEach(section.artists) { artist in
                            JellyfinArtistRow(
                                artist: artist,
                                serverID: self.serverID,
                                sourceName: nil,
                                coverArtProvider: self.coverArtProvider
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let serverID = self.serverID
                                Task { await self.library.selectDestination(.jellyfinArtist(serverID, artist.id)) }
                            }
                            .onAppear {
                                if artist.id == self.vm.artists.last?.id, self.vm.hasMorePages {
                                    Task { await self.vm.loadMore() }
                                }
                            }
                        }
                    }
                }
                if self.vm.isLoading {
                    HStack { Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Search mode

    @ViewBuilder
    private var searchBody: some View {
        let hits = self.search.artists
        if hits.isEmpty {
            if self.search.isSearching {
                ProgressView(L10n.string("Searching\u{2026}"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: self.library.searchQuery)
            }
        } else {
            VStack(spacing: 0) {
                if !self.search.failedServerNames.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: self.search.failedServerNames)
                }
                List {
                    ForEach(Self.bucket(hits: hits), id: \.letter) { bucket in
                        Section(bucket.letter) {
                            ForEach(bucket.hits) { hit in
                                JellyfinArtistRow(
                                    artist: hit.artist,
                                    serverID: hit.serverID,
                                    sourceName: hit.serverName,
                                    coverArtProvider: self.coverArtProvider
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await self.library.selectDestination(.jellyfinArtist(hit.serverID, hit.artist.id))
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Helpers

    private struct Bucket {
        let letter: String
        let hits: [JellyfinArtistHit]
    }

    /// Groups search hits by initial, each group sorted by name, with "#" last.
    private static func bucket(hits: [JellyfinArtistHit]) -> [Bucket] {
        var groups: [String: [JellyfinArtistHit]] = [:]
        for hit in hits {
            groups[JellyfinArtistsViewModel.letter(for: hit.artist.name), default: []].append(hit)
        }
        return groups
            .map { key, value in
                Bucket(
                    letter: key,
                    hits: value.sorted { $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending }
                )
            }
            .sorted { lhs, rhs in
                if lhs.letter == "#" {
                    return false
                }
                if rhs.letter == "#" {
                    return true
                }
                return lhs.letter < rhs.letter
            }
    }
}

// MARK: - JellyfinArtistRow

private struct JellyfinArtistRow: View {
    let artist: JellyfinArtist
    let serverID: UUID
    /// When non-nil, a small source pill appears next to the name.
    let sourceName: String?
    let coverArtProvider: JellyfinCoverArtProvider?

    var body: some View {
        HStack(spacing: 10) {
            JellyfinCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                itemID: self.artist.coverArtID,
                tag: self.artist.coverArtTag,
                seed: abs(self.artist.id.hashValue),
                pixelSize: 64
            )
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.artist.name)
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let name = self.sourceName, !name.isEmpty {
                        SubsonicSourcePill(name: name)
                    }
                }
                if let count = self.artist.albumCount, count > 0 {
                    Text(count == 1 ? L10n.string("1 album") : L10n.string("\(count) albums"))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([self.artist.name, self.sourceName].compactMap(\.self).joined(separator: ", "))
    }
}
