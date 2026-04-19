import SwiftUI
import UniformTypeIdentifiers

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
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    public init(vm: LibraryViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(vm: self.vm)
            } detail: {
                ContentPane(vm: self.vm)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ScanBanner(vm: self.vm)
                    }
                    .toolbar { self.toolbarItems }
            }

            NowPlayingStrip(vm: self.vm.nowPlaying)
        }
        .environmentObject(self.vm)
        .task {
            // Wire the inspector window opener before any UI loads.
            self.vm.openInspectorWindow = { self.openWindow(id: "track-inspector") }
            await self.vm.restoreUIState()
            await self.vm.refreshRoots()
            await self.vm.loadCurrentDestination()
        }
        .onDisappear {
            Task { await self.vm.saveUIState() }
        }
        .overlay {
            // Drop-target highlight border
            if self.vm.isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL, UTType.folder],
            isTargeted: self.$vm.isDragTargeted
        ) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.loadURL(from: provider) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    await self.vm.addDroppedURLs(urls)
                }
            }
            return true
        }
        .frame(minWidth: 900, minHeight: 550)
        .accessibilityIdentifier("BocanMainWindow")
        .alert(
            "Playback Error",
            isPresented: Binding(
                get: { self.vm.playbackErrorMessage != nil },
                set: { if !$0 { self.vm.playbackErrorMessage = nil } }
            )
        ) {
            Button("OK") { self.vm.playbackErrorMessage = nil }
        } message: {
            Text(self.vm.playbackErrorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SearchField(vm: self.vm.search)
                .frame(minWidth: 180, maxWidth: 280)
        }
    }

    // MARK: - Drop helper

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
