import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicArtistsView

/// Per-server Artists destination (Phase 19 step 10).
///
/// The un-filtered list is rendered as one `Section` per index bucket
/// returned by `getArtists` (Subsonic returns the full index in one call —
/// no paging). When the global search field has text, the same list shape
/// renders multi-source search results bucketed alphabetically across every
/// enabled Subsonic server, with each row decorated with a source pill.
public struct SubsonicArtistsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicArtistsViewModel
    /// Separately observed so the view re-renders when the multi-source
    /// search VM publishes new `artists` / `isSearching` / `failedServerNames`
    /// values. Without this, reading `library.subsonicSearch?.…` only
    /// triggers a redraw when `library` itself publishes — and the view
    /// would freeze on "Searching\u{2026}" until the user navigated away
    /// and back.
    @ObservedObject private var search: SubsonicMultiSourceSearchViewModel

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
            wrappedValue: SubsonicArtistsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.subsonicMetadataCache
            )
        )
        self.search = library.subsonicSearch
            ?? SubsonicMultiSourceSearchViewModel(dataSource: NoopBrowseDataSource())
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
        .navigationTitle("Artists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await self.vm.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading || self.isSearching)
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

    // MARK: - Regular mode

    @ViewBuilder
    private var regularBody: some View {
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
                                sourceName: nil,
                                coverArtProvider: self.coverArtProvider
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let sid = self.serverID
                                let aid = artist.id
                                Task { await self.library.selectDestination(.subsonicArtist(sid, aid)) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Search mode

    @ViewBuilder
    private var searchBody: some View {
        let hits = self.search.artists
        if hits.isEmpty {
            if self.search.isSearching {
                ProgressView("Searching\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: self.library.searchQuery)
            }
        } else {
            VStack(spacing: 0) {
                let failed = self.search.failedServerNames
                if !failed.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: failed)
                }
                List {
                    let buckets = Self.bucket(hits: hits)
                    ForEach(buckets, id: \.letter) { bucket in
                        Section(bucket.letter) {
                            ForEach(bucket.hits) { hit in
                                SubsonicArtistRow(
                                    artist: hit.artist,
                                    serverID: hit.serverID,
                                    sourceName: hit.serverName,
                                    coverArtProvider: self.coverArtProvider
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let sid = hit.serverID
                                    let aid = hit.artist.id
                                    Task {
                                        await self.library.selectDestination(.subsonicArtist(sid, aid))
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

    // MARK: - Helpers

    private struct ArtistBucket {
        let letter: String
        let hits: [SubsonicArtistHit]
    }

    /// Groups multi-source artist hits into A–Z buckets by leading letter,
    /// with a "#" bucket for non-alphabetic names. Mirrors the indexed
    /// layout `getArtists` already returns per server.
    private static func bucket(hits: [SubsonicArtistHit]) -> [ArtistBucket] {
        var groups: [String: [SubsonicArtistHit]] = [:]
        for hit in hits {
            let first = hit.artist.name.first.map(String.init)?.uppercased() ?? "#"
            let letter: String = first.first.map { $0.isLetter ? first : "#" } ?? "#"
            groups[letter, default: []].append(hit)
        }
        for key in groups.keys {
            groups[key]?.sort { $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending }
        }
        return groups
            .map { ArtistBucket(letter: $0.key, hits: $0.value) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter < rhs.letter
            }
    }
}

// MARK: - SubsonicArtistRow

private struct SubsonicArtistRow: View {
    let artist: ArtistID3
    let serverID: UUID
    /// When non-nil, a small source pill appears next to the artist name.
    let sourceName: String?
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
                    Text(count == 1 ? "1 album" : "\(count) albums")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.artist.name, self.sourceName]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
    }
}
