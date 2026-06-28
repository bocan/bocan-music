import Persistence
import SwiftUI

// MARK: - AlbumCell

/// A single album cell in the grid: cover art + title + artist name + track count.
private struct AlbumCell: View {
    let album: Album
    let artistName: String?
    let trackCount: Int?

    var body: some View {
        let displayArtist = self.artistName ?? L10n.string("Various Artists")
        VStack(alignment: .leading, spacing: 4) {
            // Artwork — always a 1:1 square that fills the grid cell's width.
            // `Artwork` self-applies an aspect-ratio constraint so the loaded
            // image and the gradient placeholder lay out identically.
            Group {
                if let path = album.coverArtPath {
                    Artwork(artPath: path, seed: Int(self.album.id ?? 0), size: Theme.albumGridMinWidth)
                        .accessibilityLabel(L10n.string("\(self.album.title) artwork"))
                } else {
                    GradientPlaceholder(seed: Int(self.album.id ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityLabel(L10n.string("\(self.album.title) artwork placeholder"))
                }
            }
            .frame(maxWidth: .infinity)

            // Title
            Text(self.album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            // Artist name (or "Various Artists" when no album artist is set)
            Text(displayArtist)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            // Year · track count
            let yearString = self.album.year.map { String($0) }
            let countString = self.trackCount.map { L10n.string("\($0) songs") }
            let subtitle = [yearString, countString].compactMap(\.self).joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.album.title, displayArtist, self.album.year.map(String.init)]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityHint(L10n.string("Double-tap to open album"))
    }
}

// MARK: - AlbumInteractiveCell

/// Wraps `AlbumCell` with interaction: tap, cmd-tap, keyboard focus ring,
/// and arrow-key / return-key callbacks.  Extracted into its own struct so the
/// Swift type-checker never times out on the heavy modifier chain.
private struct AlbumInteractiveCell<Menu: View>: View {
    let album: Album
    let artistName: String?
    let trackCount: Int?
    let isSelected: Bool
    let isFocused: Bool
    @FocusState.Binding var focusedAlbumID: Int64?
    let onTap: () -> Void
    let onCmdTap: () -> Void
    let onOpen: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @ViewBuilder let contextMenuContent: () -> Menu

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        AlbumCell(album: self.album, artistName: self.artistName, trackCount: self.trackCount)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: self.isFocused ? 2 : 0)
            )
            .contentShape(Rectangle())
            .scaleEffect(self.isHovered && !self.reduceMotion ? 1.04 : 1.0)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.isHovered)
            .focusable()
            .focused(self.$focusedAlbumID, equals: self.album.id)
            .focusEffectDisabled()
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { self.onCmdTap() })
            .onTapGesture { self.onTap() }
            .onHover { self.isHovered = $0 }
            .contextMenu { self.contextMenuContent() }
            .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow, .upArrow, .downArrow]) {
                self.handleKeyPress($0)
            }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return, .space:
            self.onOpen()

        case .leftArrow:
            self.onMoveLeft()

        case .rightArrow:
            self.onMoveRight()

        case .upArrow:
            self.onMoveUp()

        case .downArrow:
            self.onMoveDown()

        default:
            return .ignored
        }
        return .handled
    }
}

// MARK: - AlbumsGridView

/// Adaptive `LazyVGrid` of album cells.
///
/// Clicking an album pushes `AlbumDetailView` by setting `vm.selectedAlbumID`.
public struct AlbumsGridView: View {
    @ObservedObject public var vm: AlbumsViewModel
    public var library: LibraryViewModel
    /// Phase 4 audit L3: Cmd-click multi-select for albums.
    @State private var selection: Set<Int64> = []
    /// Phase 5: keyboard focus — which album cell has keyboard focus.
    @FocusState private var focusedAlbumID: Int64?
    /// Tracks the number of columns in the adaptive grid for arrow-key navigation.
    @State private var gridColumnCount = 3
    /// Programmatic scroll position, used to restore the grid offset on return
    /// from an album (#349).
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Live vertical scroll offset, updated continuously; snapshotted into the
    /// view model when navigating into an album so it survives the grid rebuild.
    @State private var liveScrollOffset: CGFloat = 0
    /// Scales the minimum album cell width proportionally to the user's text size setting.
    @ScaledMetric(relativeTo: .body) private var scaledAlbumMinWidth = Theme.albumGridMinWidth

    public init(vm: AlbumsViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledAlbumMinWidth), spacing: Theme.albumGridSpacing)]
    }

    public var body: some View {
        Group {
            if self.vm.isLoading {
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.albums.isEmpty {
                let activeQuery = self.library.searchQuery.trimmingCharacters(in: .whitespaces)
                if !activeQuery.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: L10n.string("No Results"),
                        message: L10n.string("No albums match \u{201C}\(activeQuery)\u{201D}.")
                    )
                } else {
                    EmptyState(
                        symbol: "square.grid.2x2",
                        title: L10n.string("No Albums"),
                        message: L10n.string("Add a music folder to start building your library."),
                        actionLabel: L10n.string("Add Music Folder")
                    ) {
                        Task { await self.library.addFolderByPicker() }
                    }
                }
            } else {
                self.albumGrid
            }
        }
        .navigationTitle(L10n.string("Albums"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                self.sortMenu
            }
        }
    }

    /// Dropdown that chooses the grid sort order (issue #349). Bound straight to
    /// the view model, which owns and persists the preference.
    private var sortMenu: some View {
        Menu {
            Picker(L10n.string("Sort By"), selection: self.sortBinding) {
                ForEach(AlbumSortOrder.allCases, id: \.rawValue) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(L10n.string("Sort"), systemImage: "arrow.up.arrow.down")
        }
        .help(L10n.string("Choose how albums are sorted"))
    }

    private var sortBinding: Binding<AlbumSortOrder> {
        Binding(
            get: { self.vm.sortOrder },
            set: { self.vm.setSortOrder($0) }
        )
    }

    // MARK: - Grid

    private var albumGrid: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                    ForEach(self.vm.albums, id: \.id) { album in
                        AlbumInteractiveCell(
                            album: album,
                            artistName: album.albumArtistID.flatMap { self.vm.artistNames[$0] },
                            trackCount: album.id.flatMap { self.vm.trackCounts[$0] },
                            isSelected: album.id.map { self.selection.contains($0) } ?? false,
                            isFocused: self.focusedAlbumID == album.id && album.id != nil,
                            focusedAlbumID: self.$focusedAlbumID,
                            onTap: {
                                guard let id = album.id else { return }
                                self.selection = []
                                self.vm.selectedAlbumID = id
                            },
                            onCmdTap: {
                                guard let id = album.id else { return }
                                if self.selection.contains(id) {
                                    self.selection.remove(id)
                                } else {
                                    self.selection.insert(id)
                                }
                            },
                            onOpen: {
                                guard let id = album.id else { return }
                                self.selection = []
                                self.vm.selectedAlbumID = id
                            },
                            onMoveLeft: { self.moveFocus(by: -1) },
                            onMoveRight: { self.moveFocus(by: +1) },
                            onMoveUp: { self.moveFocus(by: -self.gridColumnCount) },
                            onMoveDown: { self.moveFocus(by: +self.gridColumnCount) },
                            contextMenuContent: { self.albumContextMenu(album: album) }
                        )
                    }
                }
                .padding(Theme.albumGridSpacing)
            }
            .scrollPosition(self.$scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newY in
                self.liveScrollOffset = newY
            }
            .onGeometryChange(
                for: Int.self,
                of: {
                    let usable = $0.size.width - 2 * Theme.albumGridSpacing
                    return max(1, Int((usable + Theme.albumGridSpacing) /
                            (Theme.albumGridMinWidth + Theme.albumGridSpacing)))
                },
                action: { self.gridColumnCount = $0 }
            )
            .onChange(of: self.focusedAlbumID) { _, newID in
                guard newID != nil else { return }
                withAnimation { scrollProxy.scrollTo(newID, anchor: .center) }
            }
            .navigationDestination(for: Int64.self) { albumID in
                AlbumDetailView(albumID: albumID, library: self.library)
            }
            .accessibilityIdentifier(A11y.AlbumsGrid.grid)
            // Navigate to selected album.
            // Reset to nil after each navigation so that tapping the same
            // album a second time always fires (onChange fires on *change* only).
            .onChange(of: self.vm.selectedAlbumID) { _, newID in
                if let id = newID {
                    self.vm.selectedAlbumID = nil
                    // Snapshot the current scroll offset so the grid returns to it
                    // when it's rebuilt on the way back (#349).
                    self.vm.gridScrollOffset = Double(self.liveScrollOffset)
                    Task { await self.library.selectDestination(.album(id)) }
                }
            }
            // Restore the saved offset when the grid (re)appears. .scrollPosition
            // applies it once the content has laid out, so it survives the reload
            // on the way back; also re-apply when the list reloads.
            .onAppear { self.restoreScrollOffset() }
            .onChange(of: self.vm.albums.map(\.id)) { _, _ in self.restoreScrollOffset() }
        }
    }

    /// Restores the album grid to its saved scroll offset (#349).
    private func restoreScrollOffset() {
        guard self.vm.gridScrollOffset > 0 else { return }
        self.scrollPosition.scrollTo(y: CGFloat(self.vm.gridScrollOffset))
    }

    /// Moves keyboard focus by `delta` positions in the album list.
    private func moveFocus(by delta: Int) {
        let albums = self.vm.albums
        guard !albums.isEmpty else { return }
        guard let currentID = self.focusedAlbumID,
              let currentIdx = albums.firstIndex(where: { $0.id == currentID }) else {
            self.focusedAlbumID = albums.first?.id
            return
        }
        let newIdx = max(0, min(albums.count - 1, currentIdx + delta))
        self.focusedAlbumID = albums[newIdx].id
    }

    // MARK: - Context menu

    /// The set of album IDs the right-click affects: either the multi-selection
    /// (when the right-clicked album is part of it) or just this single album.
    private func targetIDs(for album: Album) -> [Int64] {
        guard let id = album.id else { return [] }
        if self.selection.contains(id), self.selection.count > 1 {
            return Array(self.selection)
        }
        return [id]
    }

    @ViewBuilder
    private func albumContextMenu(album: Album) -> some View {
        let ids = self.targetIDs(for: album)
        let multi = ids.count > 1

        if multi {
            // Replace the queue with every selected album's tracks, in place.
            Button(L10n.string("Play \(ids.count) Albums")) {
                Task { await self.library.playAlbums(albumIDs: ids) }
            }
            .disabled(ids.isEmpty)
        } else {
            // "Play Album" plays in place (no navigation); "View Album" opens the
            // album detail, which is what the old single "Play" action did (#349).
            Button(L10n.string("Play Album")) {
                guard let id = album.id else { return }
                Task { await self.library.playAlbum(albumID: id) }
            }
            Button(L10n.string("View Album")) {
                self.vm.selectedAlbumID = album.id
            }
        }

        if !multi {
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
        }

        Divider()
        // Phase 4 audit L8: wire Get Info now that Phase 8 has shipped.
        Button(L10n.string("Get Info (\(ids.count) Albums)")) {
            Task { await self.openInspector(forAlbumIDs: ids) }
        }
        .disabled(ids.isEmpty)

        Divider()
        Button(L10n.string("Remove \(ids.count) Albums from Library"), role: .destructive) {
            Task {
                await RemoveFromLibraryConfirm.albums(
                    ids: ids, soleTitle: multi ? nil : album.title, library: self.library
                )
            }
        }
        .disabled(ids.isEmpty)
    }

    /// Loads every track for the given album IDs and opens the writable tag editor.
    private func openInspector(forAlbumIDs ids: [Int64]) async {
        let repo = TrackRepository(database: self.library.database)
        var collected: [Track] = []
        for id in ids {
            if let tracks = try? await repo.fetchAll(albumID: id) {
                collected.append(contentsOf: tracks)
            }
        }
        await MainActor.run {
            self.library.showTagEditor(tracks: collected)
        }
    }
}
