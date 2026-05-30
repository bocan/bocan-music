import Acoustics
import Library
import Observability
import Scrobble
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
    private var routeVM: RouteViewModel
    /// Held as a plain reference (not @ObservedObject) so `BocanRootView` does
    /// not re-render on every scrobble-settings change. Only the sheet content
    /// (`RecentScrobblesView`) subscribes to it as @ObservedObject.
    private let scrobbleSettingsVM: ScrobbleSettingsViewModel?
    @EnvironmentObject private var windowMode: WindowModeController
    @FocusState private var searchFocused: Bool
    /// Restored to `true` whenever any modal sheet closes so keyboard focus
    /// returns to the main content area rather than being stranded.
    @FocusState private var mainContentFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tagEditorVM: TagEditorViewModel?
    @State private var identifyVM: IdentifyTrackViewModel?
    @State private var batchCoverArtVM: BatchCoverArtViewModel?
    @State private var duplicateReviewVM: DuplicateReviewViewModel?
    @AppStorage("appearance.colorScheme") private var colorSchemeKey = "system"
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    /// Phase 4 audit M8: observe so the FSEvents watcher starts/stops live
    /// when the user toggles "Watch folders for new files" in Settings,
    /// instead of waiting for the next launch.
    @AppStorage("library.watchForChanges") private var watchForChanges = true
    /// Show the first-launch consent banner until the user responds (issue #209).
    @AppStorage(MetricKitListener.consentAskedKey) private var diagnosticsConsentAsked = false
    /// Show the crash-recovery banner when the previous session ended abnormally (issue #208).
    @AppStorage("launch.didCrashPreviously") private var didCrashPreviously = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        vm: LibraryViewModel,
        lyricsVM: LyricsViewModel,
        visualizerVM: VisualizerViewModel,
        routeVM: RouteViewModel,
        scrobbleSettingsVM: ScrobbleSettingsViewModel? = nil
    ) {
        _vm = StateObject(wrappedValue: vm)
        self.lyricsVM = lyricsVM
        self.visualizerVM = visualizerVM
        self.routeVM = routeVM
        self.scrobbleSettingsVM = scrobbleSettingsVM
    }

    /// `true` once the user has added any music source — a local folder or a
    /// Subsonic server (including hidden ones). Used to hold the diagnostics
    /// consent banner back until first launch's sole call to action ("Add Music")
    /// has been satisfied, so the two prompts never compete (issue #310).
    private var libraryHasContent: Bool {
        !self.vm.libraryRoots.isEmpty
            || !self.vm.subsonicServers.isEmpty
            || !self.vm.hiddenSubsonicServers.isEmpty
    }

    /// `true` while any modal sheet is presented over the main window.
    private var anySheetOpen: Bool {
        self.tagEditorVM != nil
            || self.identifyVM != nil
            || self.vm.isPlaylistImportSheetPresented
            || self.vm.playlistExportRequest != nil
            || self.vm.isBatchCoverArtSheetPresented
            || self.vm.isDuplicateReviewSheetPresented
    }

    /// Main window chrome — split out from `body` to keep the modifier chain short
    /// enough for the Swift type-checker (which times out on very long chains).
    private var windowContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NavigationSplitView {
                    Sidebar(vm: self.vm)
                } detail: {
                    ContentPane(vm: self.vm)
                }
                .searchable(text: self.$vm.searchQuery, placement: .toolbar, prompt: "Search")
                .searchFocused(self.$searchFocused)
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
                            self.windowMode.miniPlayerOpen ? "Hide Mini Player" : "Show Mini Player",
                            systemImage: "pip.enter"
                        ) {
                            self.windowMode.toggleMiniPlayer()
                        }
                        .help("Toggle mini player (⌥⌘M)")

                        Button(
                            self.lyricsVM.paneVisible ? "Hide Lyrics" : "Show Lyrics",
                            systemImage: "text.quote"
                        ) {
                            if self.reduceMotion {
                                self.lyricsVM.paneVisible.toggle()
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    self.lyricsVM.paneVisible.toggle()
                                }
                            }
                        }
                        .help("Toggle lyrics pane (⌥⌘L)")

                        Button(
                            self.visualizerVM.paneVisible ? "Hide Visualizer" : "Show Visualizer",
                            systemImage: "waveform"
                        ) {
                            if self.reduceMotion {
                                self.visualizerVM.paneVisible.toggle()
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    self.visualizerVM.paneVisible.toggle()
                                }
                            }
                        }
                        .help("Toggle visualizer pane (⇧⌘V)")

                        Button("Identify Track", systemImage: "waveform.badge.magnifyingglass") {
                            self.vm.showIdentifyTrackForCurrentSelection()
                        }
                        .disabled(!self.vm.hasSingleTrackSelection)
                        .help("Identify track using AcoustID (⌘⌥I)")
                    }
                }

                NowPlayingStrip(vm: self.vm.nowPlaying, route: self.routeVM, scrobbleSettingsVM: self.scrobbleSettingsVM)
                    .environmentObject(self.visualizerVM)
            }

            // Lyrics and Visualizer panes are mutually exclusive — both occupy the
            // same trailing overlay slot. Visualizer wins when both are toggled on.
            if self.visualizerVM.paneVisible {
                VisualizerPane(vm: self.visualizerVM, nowPlayingVM: self.vm.nowPlaying)
            } else {
                LyricsPane(vm: self.lyricsVM, position: self.vm.nowPlaying.position) { pos in
                    Task { await self.vm.nowPlaying.scrub(to: pos) }
                }
            }
        }
        .onChange(of: self.vm.nowPlaying.nowPlayingTrackID) { _, trackID in
            self.lyricsVM.trackDidChange(trackID: trackID)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Crash-recovery banner takes priority over the diagnostics consent
            // banner (issue #208).  Collapses once the user picks Recover or
            // Start Fresh; never grabs focus so it can't cause an audio pop.
            if self.didCrashPreviously {
                CrashRecoveryBanner()
            } else if !self.diagnosticsConsentAsked, self.libraryHasContent {
                // Non-modal first-launch consent prompt (issue #209), deferred
                // until the user has added music so it doesn't compete with the
                // empty-library "Add Music" call to action (issue #310).
                DiagnosticsConsentBanner()
            }
        }
        .environmentObject(self.vm)
        .task {
            // Wire window openers before any UI loads.
            let ow = self.openWindow
            let dw = self.dismissWindow
            self.windowMode.openWindow = { id in ow(id: id) }
            self.windowMode.dismissWindow = { id in dw(id: id) }
            // Load the playlist sidebar BEFORE restoring UI state so that a
            // saved .folder destination doesn't briefly show "Folder Not Found"
            // while playlistSidebar.nodes is still empty.
            await self.vm.playlistSidebar.reload()
            // Bootstrap Subsonic clients before restoring navigation state.
            // This ensures that any persisted Subsonic destination (e.g.
            // .subsonicSongs) can load immediately without racing against the
            // background hydration task that calls reloadClients() in BocanApp.
            await self.vm.bootstrapSubsonic()
            await self.vm.restoreUIState()
            self.windowMode.restoreIfNeeded()
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
    }

    public var body: some View {
        self.windowContent
            .focused(self.$mainContentFocused)
            .frame(minWidth: 900, minHeight: 550)
            .accessibilityIdentifier("BocanMainWindow")
            .background(MainWindowGrabber().frame(width: 0, height: 0).allowsHitTesting(false))
            .background(
                // Phase 4 audit H2: persist sidebar divider position via NSSplitView
                // autosave + a settings-key fallback held on LibraryViewModel.
                SidebarWidthAutosave(initialWidth: self.vm.sidebarWidth) { width in
                    self.vm.sidebarWidth = width
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            )
            .onChange(of: self.vm.searchFocusRequestID) { _, _ in
                // Phase 4 audit H5: ⌘F (Find) focuses the search field.
                self.searchFocused = true
            }
            .onChange(of: self.anySheetOpen) { _, isOpen in
                // Keyboard focus phase: return focus to the main content area when
                // any modal sheet closes so Tab / arrow keys remain reachable.
                if !isOpen { self.mainContentFocused = true }
            }
            .onChange(of: self.watchForChanges) { _, _ in
                // Phase 4 audit M8: live-toggle the FSEvents watcher when the
                // Settings switch flips, instead of waiting for next launch.
                Task { await self.vm.startOrStopWatcher() }
            }
            .alert(
                "Playback Error",
                isPresented: self.playbackErrorBinding
            ) {
                Button("OK") { self.vm.playbackErrorMessage = nil }
            } message: {
                Text(self.vm.playbackErrorMessage ?? "")
            }
            .alert(
                "Re-scan Failed",
                isPresented: self.rescanErrorBinding
            ) {
                Button("OK") { self.vm.rescanErrorMessage = nil }
            } message: {
                Text(self.vm.rescanErrorMessage ?? "")
            }
            .modifier(ClearQueueConfirmationModifier(
                isPresented: self.$vm.clearQueueConfirmationPresented,
                itemCount: self.vm.clearQueueItemCount
            ) {
                Task { await self.vm.clearQueue() }
            })
            .overlay(alignment: .top) {
                // Phase 5.5 audit M2: lightweight toast surface for transient
                // confirmations (e.g. "Re-scanned «Title»"). Auto-dismisses
                // via LibraryViewModel.showToast after 2 seconds.
                if let toast = self.vm.toast {
                    ToastBanner(message: toast)
                        .padding(.top, 12)
                        .transition(self.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(toast.text)
                }
            }
            .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.18), value: self.vm.toast)
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
                    self.identifyVM = IdentifyTrackViewModel(
                        track: track,
                        queue: queue,
                        editService: svc,
                        artistRepo: self.vm.artistRepo,
                        albumRepo: self.vm.albumRepo
                    )
                } else {
                    self.identifyVM = nil
                }
            }
            .sheet(item: self.$identifyVM) { identVM in
                IdentifyTrackSheet(vm: identVM)
                    .onDisappear {
                        let didApply = identVM.didApply
                        let openTagEditor = identVM.openTagEditorAfterDismiss
                        // Capture the track ID before clearing identifyTrack.
                        let trackID = self.vm.identifyTrack?.id
                        self.vm.identifyTrack = nil
                        if didApply, let id = trackID {
                            Task { await self.vm.refreshTracks(ids: [id]) }
                        }
                        if openTagEditor, let id = trackID {
                            self.vm.tagEditorTrackIDs = [id]
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
            .onChange(of: self.vm.isBatchCoverArtSheetPresented) { _, presented in
                if presented {
                    self.batchCoverArtVM = BatchCoverArtViewModel(
                        database: self.vm.database,
                        albumRepo: self.vm.albumRepo,
                        artistRepo: self.vm.artistRepo
                    )
                } else {
                    self.batchCoverArtVM = nil
                }
            }
            .sheet(isPresented: self.$vm.isBatchCoverArtSheetPresented) {
                if let batchVM = self.batchCoverArtVM {
                    BatchCoverArtSheet(
                        vm: batchVM,
                        isPresented: self.$vm.isBatchCoverArtSheetPresented
                    )
                }
            }
            .onChange(of: self.vm.isDuplicateReviewSheetPresented) { _, presented in
                if presented {
                    self.duplicateReviewVM = DuplicateReviewViewModel(
                        database: self.vm.database,
                        library: self.vm
                    )
                } else {
                    self.duplicateReviewVM = nil
                }
            }
            .sheet(isPresented: self.$vm.isDuplicateReviewSheetPresented) {
                if let dupVM = self.duplicateReviewVM {
                    DuplicateReviewSheet(
                        vm: dupVM,
                        isPresented: self.$vm.isDuplicateReviewSheetPresented
                    )
                }
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

    private var rescanErrorBinding: Binding<Bool> {
        Binding(
            get: { self.vm.rescanErrorMessage != nil },
            set: { if !$0 { self.vm.rescanErrorMessage = nil } }
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

// MARK: - Clear-queue confirmation (issue #260)

/// Hosts the "Clear the queue?" confirmation as a standalone modifier so the
/// large `BocanRootView.body` modifier chain stays within the Swift
/// type-checker's complexity budget.
private struct ClearQueueConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let itemCount: Int
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Clear the queue?", isPresented: self.$isPresented) {
            Button("Clear Queue", role: .destructive, action: self.onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the \(self.itemCount) tracks in your queue and stops playback.")
        }
    }
}
