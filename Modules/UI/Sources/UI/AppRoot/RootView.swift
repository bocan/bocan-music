import Acoustics
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
    @ObservedObject private var lyricsVM: LyricsViewModel
    @ObservedObject private var visualizerVM: VisualizerViewModel
    @EnvironmentObject private var windowMode: WindowModeController
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tagEditorVM: TagEditorViewModel?
    @State private var identifyVM: IdentifyTrackViewModel?
    @AppStorage("appearance.colorScheme") private var colorSchemeKey = "system"
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    public init(vm: LibraryViewModel, lyricsVM: LyricsViewModel, visualizerVM: VisualizerViewModel) {
        _vm = StateObject(wrappedValue: vm)
        self.lyricsVM = lyricsVM
        self.visualizerVM = visualizerVM
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NavigationSplitView {
                    Sidebar(vm: self.vm)
                } detail: {
                    ContentPane(vm: self.vm)
                }
                .searchable(text: self.$vm.searchQuery, placement: .toolbar, prompt: "Search")
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") {
                            Task { await self.vm.goBack() }
                        }
                        .disabled(!self.vm.canGoBack)
                        .help("Back")
                        .keyboardShortcut("[", modifiers: .command)

                        Button("Forward", systemImage: "chevron.right") {
                            Task { await self.vm.goForward() }
                        }
                        .disabled(!self.vm.canGoForward)
                        .help("Forward")
                        .keyboardShortcut("]", modifiers: .command)

                        Button(
                            self.lyricsVM.paneVisible ? "Hide Lyrics" : "Show Lyrics",
                            systemImage: "text.quote"
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.lyricsVM.paneVisible.toggle()
                            }
                        }
                        .help("Toggle lyrics pane (⌘L)")
                    }
                }

                NowPlayingStrip(vm: self.vm.nowPlaying)
                    .environmentObject(self.visualizerVM)
            }

            // Lyrics and Visualizer panes are mutually exclusive — both occupy the
            // same trailing overlay slot. Visualizer wins when both are toggled on.
            if self.visualizerVM.paneVisible {
                VisualizerPane(vm: self.visualizerVM)
            } else {
                LyricsPane(vm: self.lyricsVM, position: self.vm.nowPlaying.position) { pos in
                    Task { await self.vm.nowPlaying.scrub(to: pos) }
                }
            }
        }
        .onChange(of: self.vm.nowPlaying.nowPlayingTrackID) { _, trackID in
            self.lyricsVM.trackDidChange(trackID: trackID)
        }
        .environmentObject(self.vm)
        .task {
            // Wire window openers before any UI loads.
            self.vm.openInspectorWindow = { self.openWindow(id: "track-inspector") }
            let ow = self.openWindow
            let dw = self.dismissWindow
            self.windowMode.openWindow = { id in ow(id: id) }
            self.windowMode.dismissWindow = { id in dw(id: id) }
            await self.vm.restoreUIState()
            await self.vm.refreshRoots()
            await self.vm.loadCurrentDestination()
            self.vm.triggerScan()
            await self.vm.startOrStopWatcher()
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
        .background(MainWindowGrabber().frame(width: 0, height: 0).allowsHitTesting(false))
        .alert(
            "Playback Error",
            isPresented: self.playbackErrorBinding
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
        .onChange(of: self.vm.identifyTrack?.id) { _, _ in
            if let track = self.vm.identifyTrack,
               let queue = self.vm.fingerprintQueue,
               let svc = self.vm.metadataEditService {
                self.identifyVM = IdentifyTrackViewModel(track: track, queue: queue, editService: svc)
            } else {
                self.identifyVM = nil
            }
        }
        .sheet(item: self.$identifyVM) { identVM in
            IdentifyTrackSheet(vm: identVM)
                .onDisappear {
                    let didApply = identVM.didApply
                    // Capture the track ID before clearing identifyTrack.
                    let trackID = self.vm.identifyTrack?.id
                    self.vm.identifyTrack = nil
                    if didApply, let id = trackID {
                        Task { await self.vm.refreshTracks(ids: [id]) }
                    }
                }
        }
        .sheet(isPresented: self.$vm.isPlaylistImportSheetPresented) {
            PlaylistImportSheet(
                isPresented: self.$vm.isPlaylistImportSheetPresented,
                importer: self.vm.playlistImporter
            ) { id in
                Task { await self.vm.playlistSidebar.reload() }
                self.vm.selectedDestination = .playlist(id)
            }
        }
        .sheet(item: self.$vm.playlistExportRequest) { req in
            PlaylistExportSheet(
                isPresented: Binding(
                    get: { self.vm.playlistExportRequest != nil },
                    set: { if !$0 { self.vm.playlistExportRequest = nil } }
                ),
                exporter: self.vm.playlistExporter,
                playlistID: req.id,
                playlistName: req.name
            )
        }
        .onKeyPress(.init("i"), phases: .down) { event in
            guard event.modifiers == [.command, .option] else { return .ignored }
            self.vm.showIdentifyTrackForCurrentSelection()
            return .handled
        }
        .onAppear { self.applyAppearance(self.colorSchemeKey) }
        .onChange(of: self.colorSchemeKey) { _, newKey in self.applyAppearance(newKey) }
        .tint(AccentPalette.color(for: self.accentColorKey))
    }

    // MARK: - Helpers

    /// Sets `NSApp.appearance` so the change takes effect immediately for every
    /// window, avoiding the half-repainted artefact that `.preferredColorScheme`
    /// can leave when transitioning from a forced scheme back to System.
    private func applyAppearance(_ key: String) {
        switch key {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)

        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)

        default:
            NSApp.appearance = nil // follow System
        }
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { self.vm.playbackErrorMessage != nil },
            set: { if !$0 { self.vm.playbackErrorMessage = nil } }
        )
    }

    private var tagEditorBinding: Binding<Bool> {
        Binding(
            get: { self.tagEditorVM != nil },
            set: {
                if !$0 {
                    let didSave = self.tagEditorVM?.didSave == true
                    // Capture IDs before clearing state.
                    let editedIDs = self.vm.tagEditorTrackIDs ?? []
                    self.tagEditorVM = nil
                    self.vm.tagEditorTrackIDs = nil
                    if didSave {
                        // Refresh only the affected rows — preserves scroll position.
                        Task { await self.vm.refreshTracks(ids: editedIDs) }
                    }
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
