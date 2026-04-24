import Library
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
    @State private var tagEditorVM: TagEditorViewModel?

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
            }
            .searchable(text: self.$vm.searchQuery, placement: .toolbar, prompt: "Search")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        Task { await self.vm.goBack() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!self.vm.canGoBack)
                    .help("Back")
                    .keyboardShortcut("[", modifiers: .command)

                    Button {
                        Task { await self.vm.goForward() }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!self.vm.canGoForward)
                    .help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
                }
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
        .onChange(of: self.vm.tagEditorTrackIDs) { _, ids in
            if let ids, !ids.isEmpty, let svc = self.vm.metadataEditService {
                self.tagEditorVM = TagEditorViewModel(service: svc, trackIDs: ids)
            } else {
                self.tagEditorVM = nil
            }
        }
        .sheet(isPresented: self.tagEditorBinding) {
            if let tagVM = self.tagEditorVM {
                TagEditorSheet(vm: tagVM, isPresented: self.tagEditorBinding)
            }
        }
    }

    // MARK: - Helpers

    private var tagEditorBinding: Binding<Bool> {
        Binding(
            get: { self.tagEditorVM != nil },
            set: {
                if !$0 {
                    self.tagEditorVM = nil
                    self.vm.tagEditorTrackIDs = nil
                }
            }
        )
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
