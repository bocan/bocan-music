import Persistence
import SwiftUI

// MARK: - ArtistDetailView

/// Artist header + optional album grid + full-featured track table.
public struct ArtistDetailView: View {
    public let artistID: Int64
    public var library: LibraryViewModel

    @State private var artist: Artist?
    @State private var albums: [Album] = []
    @State private var albumTrackCounts: [Int64: Int] = [:]
    /// Programmatic scroll position for the album strip, used to restore its
    /// offset on return from one of the artist's albums (#349).
    @State private var albumScrollPosition = ScrollPosition(edge: .top)
    /// Live vertical offset of the album strip, snapshotted into the library
    /// view model when opening an album so it survives this view's rebuild.
    @State private var liveAlbumScrollOffset: CGFloat = 0
    /// Scales the minimum album cell width proportionally to the user's text size setting.
    @ScaledMetric(relativeTo: .body) private var scaledAlbumMinWidth = Theme.albumGridMinWidth

    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledAlbumMinWidth), spacing: Theme.albumGridSpacing)]
    }

    public init(artistID: Int64, library: LibraryViewModel) {
        self.artistID = artistID
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Artist header
            if let artist {
                self.artistHeader(artist)
                    .padding(20)
                    .background(Color.bgSecondary)
                    .contextMenu {
                        Button(L10n.string("Remove Artist from Library"), role: .destructive) {
                            Task {
                                await RemoveFromLibraryConfirm.artist(
                                    id: self.artistID, name: artist.name, library: self.library
                                )
                            }
                        }
                    }
                Divider()
            }

            // Albums section — scrollable, capped so Songs table gets most of the space
            if !self.albums.isEmpty {
                self.sectionLabel(L10n.string("Albums"), count: self.albums.count)
                ScrollView {
                    LazyVGrid(columns: self.albumColumns, spacing: Theme.albumGridSpacing) {
                        ForEach(self.albums, id: \.id) { album in
                            self.albumCell(album, trackCount: album.id.flatMap { self.albumTrackCounts[$0] })
                        }
                    }
                    .padding(Theme.albumGridSpacing)
                }
                .scrollPosition(self.$albumScrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newY in
                    self.liveAlbumScrollOffset = newY
                }
                .frame(maxHeight: 260)
                Divider()
            }

            // Songs — full TracksView with context menus, drag, columns, sorting
            self.sectionLabel(L10n.string("Songs"), count: self.library.tracks.rows.count)
            TracksView(vm: self.library.tracks, library: self.library, sortable: true)
        }
        .task {
            await self.load()
        }
        // Restore the album strip's saved offset when the albums load on a
        // rebuild. This lives on the always-present root so it fires on the
        // empty -> populated transition; the strip's own ScrollView is gated
        // behind `if !albums.isEmpty`, so an onChange there would never fire (#349).
        .onChange(of: self.albums.map(\.id)) { _, _ in self.restoreAlbumScrollOffset() }
    }

    // MARK: - Sub-views

    private func artistHeader(_ artist: Artist) -> some View {
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
                    if !self.albums.isEmpty {
                        Text(localized: "\(self.albums.count) albums")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    let trackCount = self.library.tracks.rows.count
                    if !self.albums.isEmpty, trackCount > 0 {
                        Text(verbatim: "·")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    if trackCount > 0 {
                        Text(localized: "\(trackCount) songs")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            Spacer()
        }
    }

    private func sectionLabel(_ title: String, count: Int? = nil) -> some View {
        let label = count.map { L10n.string("\(title) (\($0))") } ?? title
        return Text(label)
            .font(Typography.title)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSecondary)
    }

    private func albumCell(_ album: Album, trackCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let path = album.coverArtPath {
                    Artwork(artPath: path, seed: Int(album.id ?? 0), size: Theme.albumGridMinWidth)
                        .accessibilityLabel(L10n.string("\(album.title) artwork"))
                } else {
                    GradientPlaceholder(seed: Int(album.id ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityLabel(L10n.string("\(album.title) artwork placeholder"))
                }
            }
            .frame(maxWidth: .infinity)

            Text(album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            // Year · track count
            let yearString = album.year.map { String($0) }
            let countString = trackCount.map { L10n.string("\($0) songs") }
            let subtitle = [yearString, countString].compactMap(\.self).joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = album.id {
                self.openAlbum(id)
            }
        }
        .contextMenu {
            self.albumContextMenu(album: album)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [album.title, self.artist?.name, album.year.map(String.init)]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityHint(L10n.string("Double-tap to open album"))
    }

    @ViewBuilder
    private func albumContextMenu(album: Album) -> some View {
        Button(L10n.string("Play Album")) {
            if let id = album.id {
                self.openAlbum(id)
            }
        }
        .disabled(album.id == nil)

        Divider()
        Toggle(L10n.string("Force Gapless Playback"), isOn: Binding(
            get: { album.forceGapless },
            set: { forced in
                if let id = album.id {
                    Task { await self.library.setAlbumForceGapless(albumID: id, forced: forced) }
                }
            }
        ))
        Toggle(L10n.string("Exclude from Shuffle"), isOn: Binding(
            get: { album.excludedFromShuffle },
            set: { excluded in
                if let id = album.id {
                    Task { await self.library.setAlbumExcludedFromShuffle(albumID: id, excluded: excluded) }
                }
            }
        ))

        Divider()
        Button(L10n.string("Get Info")) {
            if let id = album.id {
                Task { await self.openInspector(forAlbumID: id) }
            }
        }
        .disabled(album.id == nil)

        Divider()
        Button(L10n.string("Remove Album from Library"), role: .destructive) {
            if let id = album.id {
                Task {
                    await RemoveFromLibraryConfirm.albums(
                        ids: [id], soleTitle: album.title, library: self.library
                    )
                }
            }
        }
        .disabled(album.id == nil)
    }

    /// Navigates to an album, snapshotting the album strip's current scroll
    /// offset first so it can be restored when this view is rebuilt on the way
    /// back (#349).
    private func openAlbum(_ id: Int64) {
        self.library.artistAlbumScrollOffsets[self.artistID] = Double(self.liveAlbumScrollOffset)
        Task { await self.library.selectDestination(.album(id)) }
    }

    /// Restores the album strip to the offset saved for this artist.
    private func restoreAlbumScrollOffset() {
        guard let offset = self.library.artistAlbumScrollOffsets[self.artistID], offset > 0 else { return }
        self.albumScrollPosition.scrollTo(y: CGFloat(offset))
    }

    private func openInspector(forAlbumID id: Int64) async {
        let repo = TrackRepository(database: self.library.database)
        guard let tracks = try? await repo.fetchAll(albumID: id) else { return }
        await MainActor.run {
            self.library.showTagEditor(tracks: tracks)
        }
    }

    // MARK: - Data loading

    private func load() async {
        // Fetch albums by track artist (not album artist) so compilation appearances
        // show up — e.g. "A Day to Remember" on "Various Artists" compilation albums.
        async let albumsFetch: [Album] = await (try? AlbumRepository(
            database: self.library.database
        ).fetchAll(trackArtistID: self.artistID)) ?? []
        async let artistFetch = try? await ArtistRepository(database: self.library.database).fetch(id: self.artistID)
        async let trackCountsFetch = try? await AlbumRepository(database: self.library.database).fetchTrackCounts()
        // Load tracks via the shared TracksViewModel so TracksView gets full column data,
        // context menus, drag-to-playlist, sorting, and selection for free.
        async let trackLoad: Void = self.library.tracks.load(artistID: self.artistID)

        self.albums = await albumsFetch
        self.artist = await artistFetch
        self.albumTrackCounts = await trackCountsFetch ?? [:]
        _ = await trackLoad
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
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.artists.isEmpty {
                let activeQuery = self.library.searchQuery.trimmingCharacters(in: .whitespaces)
                if !activeQuery.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: L10n.string("No Results"),
                        message: L10n.string("No artists match \u{201C}\(activeQuery)\u{201D}.")
                    )
                } else {
                    EmptyState(
                        symbol: "music.mic",
                        title: L10n.string("No Artists"),
                        message: L10n.string("Add a music folder to start building your library."),
                        actionLabel: L10n.string("Add Music Folder")
                    ) {
                        Task { await self.library.addFolderByPicker() }
                    }
                }
            } else {
                self.artistList
            }
        }
        .navigationTitle(L10n.string("Artists"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.sortBinding, help: L10n.string("Choose how artists are sorted"))
            }
        }
    }

    /// Bridges the sort menu to the view model, which owns and persists the
    /// preference and re-sorts in place on change.
    private var sortBinding: Binding<ArtistSortOrder> {
        Binding(
            get: { self.vm.sortOrder },
            set: { self.vm.setSortOrder($0) }
        )
    }

    private var artistList: some View {
        ScrollViewReader { proxy in
            self.artistListContent
                // Re-center the last-visited artist when the list (re)appears or
                // reloads, so returning from an artist lands where the user left
                // off rather than back at the top.
                .onAppear { self.restoreScrollPosition(proxy) }
                .onChange(of: self.vm.artists.map(\.id)) { _, _ in self.restoreScrollPosition(proxy) }
        }
    }

    /// Restores the artist list to the last-visited artist, centered, so a round
    /// trip into an artist detail view returns to roughly where the user was.
    private func restoreScrollPosition(_ proxy: ScrollViewProxy) {
        guard self.vm.lastVisitedArtistID != nil else { return }
        proxy.scrollTo(self.vm.lastVisitedArtistID, anchor: .center)
    }

    private var artistListContent: some View {
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

                    if let id = artist.id {
                        let albumCount = self.vm.albumCounts[id] ?? 0
                        let trackCount = self.vm.trackCounts[id] ?? 0
                        if albumCount > 0 || trackCount > 0 {
                            let albumPart = L10n.string("\(albumCount) albums")
                            let songPart = L10n.string("\(trackCount) songs")
                            Text(localized: "\(albumPart), \(songPart)")
                                .font(Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(artist.name)
            .contextMenu {
                if let id = artist.id {
                    Button(L10n.string("Remove Artist from Library"), role: .destructive) {
                        Task {
                            await RemoveFromLibraryConfirm.artist(
                                id: id, name: artist.name, library: self.library
                            )
                        }
                    }
                }
            }
        }
        // Reset to nil so the same artist can be re-selected on the next tap.
        .onChange(of: self.vm.selectedArtistID) { _, id in
            if let id {
                self.vm.selectedArtistID = nil
                // Snapshot the visited artist so the list scrolls it back into
                // view when it's rebuilt on the way back (#349-style restore).
                self.vm.lastVisitedArtistID = id
                Task { await self.library.selectDestination(.artist(id)) }
            }
        }
    }
}
