import Persistence
import SwiftUI

// MARK: - TracksView

/// Full-width table of tracks.
///
/// - Selection is a `Set<Track.ID>` (multi-select with shift-range, ⌘-toggle).
/// - Double-click or `Return` triggers the play action.
/// - `Space` toggles play/pause via the now-playing strip.
/// - Right-click opens the standard context menu.
///
/// Column-header sorting is only enabled when `sortable == true`.
/// With tens of thousands of rows, sorting via header click is an
/// expensive operation that also fights SwiftUI's update cycle, so the
/// full-library "Songs" view disables it and relies on load-time
/// ordering instead.  Filtered contexts (album, artist, genre,
/// composer, smart folder, active search) are small enough that
/// header sort is both useful and performant.
public struct TracksView: View {
    @ObservedObject public var vm: TracksViewModel
    public var library: LibraryViewModel
    public var title: String?
    public var sortable: Bool

    /// Observed separately so that changes to `nowPlayingTrackID` / `isPlaying`
    /// invalidate this view (SwiftUI doesn't traverse nested ObservableObjects).
    @ObservedObject private var nowPlaying: NowPlayingViewModel

    /// Controls Table column visibility/order.  Persisted across launches
    /// via `@AppStorage` on a Codable JSON blob below.
    @State var columnCustomization = TableColumnCustomization<TrackRow>()

    /// Raw storage for `columnCustomization`.  `TableColumnCustomization`
    /// is `Codable`; we round-trip it through JSON so SwiftUI's Table
    /// column picker, reordering, and width drags stick across runs.
    @AppStorage("tracksView.columnCustomization.v1")
    private var columnCustomizationData: Data = .init()

    /// Local sort state.  Owned by the View (not the VM) so that
    /// Table's per-frame binding writes never fire `objectWillChange`
    /// on `TracksViewModel`.  Pushed into the VM via `.onChange` below.
    @State var sortOrder: [KeyPathComparator<TrackRow>] = TracksViewModel.defaultSortOrder

    @EnvironmentObject private var libraryEnv: LibraryViewModel

    public init(
        vm: TracksViewModel,
        library: LibraryViewModel,
        title: String? = nil,
        sortable: Bool = true
    ) {
        self.vm = vm
        self.library = library
        self.nowPlaying = library.nowPlaying
        self.title = title
        self.sortable = sortable
    }

    public var body: some View {
        Group {
            if self.vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.rows.isEmpty {
                EmptyState(
                    symbol: "music.note",
                    title: "No Songs",
                    message: "Add a music folder to start building your library.",
                    actionLabel: "Add Music Folder"
                ) {
                    Task { await self.libraryEnv.addFolderByPicker() }
                }
            } else {
                self.trackTable
            }
        }
        .navigationTitle(self.title ?? "Songs")
        .toolbar {
            if self.sortable, self.sortOrder != TracksViewModel.defaultSortOrder {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Sort") {
                        self.sortOrder = TracksViewModel.defaultSortOrder
                    }
                    .help("Reset to default sort order")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }
        .onChange(of: self.sortOrder) { _, newOrder in
            self.vm.applySort(newOrder)
        }
        .onChange(of: self.columnCustomization) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                self.columnCustomizationData = data
            }
        }
        .onAppear {
            // Seed local sort state from the VM (e.g. restored UIStateV1).
            if self.sortOrder != self.vm.sortOrder {
                self.sortOrder = self.vm.sortOrder
            }
            // Restore persisted column visibility / order / widths.
            if !self.columnCustomizationData.isEmpty,
               let decoded = try? JSONDecoder().decode(
                   TableColumnCustomization<TrackRow>.self,
                   from: self.columnCustomizationData
               ) {
                self.columnCustomization = decoded
            }
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var trackTable: some View {
        if self.sortable {
            self.sortableTable
        } else {
            self.plainTable
        }
    }

    /// Shared context menu, selection, and appearance modifiers applied
    /// to both the sortable and non-sortable Table variants.
    var tableChromeModifier: TableChromeModifier {
        TableChromeModifier(
            vm: self.vm,
            library: self.library,
            nowPlaying: self.nowPlaying,
            contextMenu: { ids in AnyView(self.trackContextMenu(ids: ids)) },
            syncSelectionToNowPlaying: { self.syncSelectionToNowPlaying() }
        )
    }

    private func syncSelectionToNowPlaying() {
        guard let id = self.nowPlaying.nowPlayingTrackID else { return }
        guard self.vm.rows.contains(where: { $0.id == id }) else { return }
        if self.vm.selection != [id] {
            self.vm.selection = [id]
        }
    }
}

// MARK: - TableChromeModifier

/// Shared selection, context-menu, and `nowPlaying` sync chrome applied
/// to both the sortable and non-sortable `Table` variants in
/// `TracksView`.  Kept as a single modifier so the two Table bodies
/// stay in sync and the Swift 6 result builders can still infer
/// column-builder generics.
struct TableChromeModifier: ViewModifier {
    let vm: TracksViewModel
    let library: LibraryViewModel
    let nowPlaying: NowPlayingViewModel
    let contextMenu: (Set<Track.ID>) -> AnyView
    let syncSelectionToNowPlaying: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                self.contextMenu(ids)
            } primaryAction: { ids in
                if let trackID = ids.first,
                   let track = vm.rows.first(where: { $0.id == trackID })?.track {
                    Task { await self.library.play(track: track) }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier(A11y.TracksTable.table)
            .onAppear { self.syncSelectionToNowPlaying() }
            .onChange(of: self.nowPlaying.nowPlayingTrackID) { _, _ in
                self.syncSelectionToNowPlaying()
            }
    }
}
