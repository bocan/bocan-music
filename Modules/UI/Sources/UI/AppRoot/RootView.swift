import SwiftUI

// MARK: - BocanRootView

/// The top-level view for the app window.
///
/// Composes a `NavigationSplitView` (sidebar | content) with a
/// `NowPlayingStrip` overlay at the bottom.  The optional detail column
/// is reserved for `AlbumDetailView` and `ArtistDetailView` — those are
/// pushed via `NavigationLink` rather than swapped here to avoid macOS
/// bugs with dynamic detail swapping.
///
/// `LibraryViewModel` is created by the app and injected here.  It is also
/// placed in the environment so deeply nested views can reach it without
/// passing it manually through every level.
public struct BocanRootView: View {
    @StateObject private var vm: LibraryViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool

    public init(vm: LibraryViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                Sidebar(vm: self.vm)
            } detail: {
                ContentPane(vm: self.vm)
                    .toolbar { self.toolbarItems }
            }

            NowPlayingStrip(vm: self.vm.nowPlaying)
        }
        .environmentObject(self.vm)
        .task {
            await self.vm.restoreUIState()
            await self.vm.loadCurrentDestination()
        }
        .onDisappear {
            Task { await self.vm.saveUIState() }
        }
        .frame(minWidth: 900, minHeight: 550)
        .accessibilityIdentifier("BocanMainWindow")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(Theme.Animation.default) {
                    self.columnVisibility = self.columnVisibility == .all ? .detailOnly : .all
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
            .accessibilityLabel("Toggle Sidebar")
        }

        ToolbarItem(placement: .primaryAction) {
            SearchField(vm: self.vm.search)
                .frame(minWidth: 180, maxWidth: 280)
        }
    }
}
