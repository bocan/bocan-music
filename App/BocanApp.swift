import AppKit
import AudioEngine
import Library
import Observability
import Persistence
import Playback
import Scrobble
import SwiftUI
import UI
import UserNotifications

/// Sendable wrapper used only during synchronous app init to transfer the
/// Database actor across the Task.detached boundary.  The semaphore enforces
/// strict single-writer / single-reader ordering, so @unchecked is safe here.
private final class _InitBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

// MARK: - AppDelegate

/// Handles `applicationShouldTerminateAfterLastWindowClosed`, `⌘W` hiding,
/// and `UNUserNotificationCenter` delegate callbacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        // Register as the notification delegate early so tap-to-foreground works.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running when all windows are closed; Dock or menubar can reopen.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Dock click when no visible windows → reopen main window.
            (sender.mainWindow ?? sender.windows.first { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tapping a track-change banner brings the app to the foreground.
    /// `nonisolated` because UNUserNotificationCenter may invoke this off the main thread;
    /// AppKit work is dispatched onto the main actor explicitly.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Dispatch AppKit work to main actor; call completion synchronously so
        // it doesn't have to cross actor boundaries (it isn't Sendable).
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }

    /// Suppress banners while the app is active (belt-and-suspenders;
    /// `NowPlayingViewModel` already gates on `NSApp.isActive` before posting).
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}

// MARK: - BocanApp

@main
struct BocanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// @State (not @Published/@AppStorage) for isInserted: — see MenuBarExtraKey.swift.
    /// SwiftUI calls the isInserted binding's setter during scene updates; if that setter
    /// fires objectWillChange on an ObservableObject, it re-enters the transaction loop
    /// and causes a "publishing during view updates" storm.  @State is handled internally
    /// by SwiftUI without re-entering the graph.  Settings writes to this via the
    /// menuBarExtraEnabled EnvironmentKey, which propagates as a plain Binding<Bool>.
    @State private var showMenuBarExtra = UserDefaults.standard.bool(forKey: "general.showMenuBarExtra")

    private let log = AppLogger.make(.app)
    private let database: Database
    private let engine: AudioEngine
    private let player: QueuePlayer
    // All four are private let, not @StateObject. @StateObject would subscribe App.body
    // to objectWillChange on each, rebuilding the menu bar on every selection change,
    // playback tick, or scan update. Child views and environment objects observe these
    // instances directly; BocanApp.body only needs the references, not reactivity.
    private let libraryViewModel: LibraryViewModel
    private let dspViewModel: DSPViewModel
    private let miniPlayerViewModel: MiniPlayerViewModel
    private let windowMode: WindowModeController
    private let dockTile: DockTileController
    private let lyricsService: LyricsService
    private let lyricsViewModel: LyricsViewModel
    private let visualizerViewModel: VisualizerViewModel
    private let scrobbleService: ScrobbleService
    private let scrobbleSettingsViewModel: ScrobbleSettingsViewModel

    var body: some Scene {
        // MARK: Main window

        WindowGroup("Bòcan", id: "main") {
            BocanRootView(
                vm: self.libraryViewModel,
                lyricsVM: self.lyricsViewModel,
                visualizerVM: self.visualizerViewModel
            )
            .environmentObject(self.dspViewModel)
            .environmentObject(self.windowMode)
            .onAppear { self.dockTile.start(observing: self.libraryViewModel.nowPlaying) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            BocanCommands(
                vm: self.libraryViewModel,
                windowMode: self.windowMode,
                lyricsVM: self.lyricsViewModel,
                visualizerVM: self.visualizerViewModel
            )
        }

        // MARK: Mini player

        MiniPlayerWindow(vm: self.miniPlayerViewModel)
            .environmentObject(self.windowMode)
            .environmentObject(self.libraryViewModel)

        // MARK: Settings

        Settings {
            SettingsScene(scrobbleViewModel: self.scrobbleSettingsViewModel)
                .environmentObject(self.dspViewModel)
                .environmentObject(self.libraryViewModel)
                .environment(\.menuBarExtraEnabled, self.$showMenuBarExtra)
        }

        // MARK: Track inspector

        Window("Track Info", id: "track-inspector") {
            InspectorWindowContent(vm: self.libraryViewModel)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)

        // MARK: Visualizer fullscreen

        Window("Visualizer", id: "visualizer-fullscreen") {
            VisualizerFullscreenView(vm: self.visualizerViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)

        // MARK: Menu bar widget

        MenuBarExtra("Bòcan", systemImage: "music.note", isInserted: self.$showMenuBarExtra) {
            MenuBarExtraScene(vm: self.libraryViewModel.nowPlaying)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: self.showMenuBarExtra) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "general.showMenuBarExtra")
        }
    }

    init() {
        Self.registerDefaults()

        self.log.info("app.launched", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"])
        #if os(macOS)
            MetricKitListener.shared.start()
        #endif

        // Initialise the database synchronously on the calling thread.
        // priority: .userInitiated matches the waiting thread (main = .userInteractive)
        // so the OS doesn't deprioritise this task while we're blocking on it,
        // which would cause a Thread Performance Checker priority-inversion warning
        // and a visible startup freeze.
        let semaphore = DispatchSemaphore(value: 0)
        let box = _InitBox<Database>()
        Task.detached(priority: .userInitiated) {
            do {
                box.value = try await Database(location: .application)
            } catch {
                fatalError("Failed to open application database: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let db = box.value else {
            fatalError("Database initialisation completed without a value")
        }

        let presetStore = PresetStore()
        let eng = AudioEngine(presets: presetStore)

        // Build the scrobble service before the player so the sink can be wired in.
        let scrobbleParts = Self.makeScrobble(database: db, log: self.log)
        let scrobble = scrobbleParts.service
        self.scrobbleService = scrobble
        self.scrobbleSettingsViewModel = scrobbleParts.viewModel

        let qp = QueuePlayer(engine: eng, database: db, scrobbleSink: scrobble)
        let scanner = LibraryScanner(database: db)

        self.database = db
        self.engine = eng
        self.player = qp

        let lvm = LibraryViewModel(database: db, engine: qp, scanner: scanner)
        self.libraryViewModel = lvm
        self.dspViewModel = DSPViewModel(engine: eng, presetStore: presetStore)
        self.miniPlayerViewModel = MiniPlayerViewModel(nowPlaying: lvm.nowPlaying)
        self.windowMode = WindowModeController()
        self.dockTile = DockTileController()

        let lsvc = LyricsService(database: db, fetcher: LRClibClient())
        self.lyricsService = lsvc
        self.lyricsViewModel = LyricsViewModel(service: lsvc)
        self.visualizerViewModel = VisualizerViewModel(engine: eng)

        // Forward NSWorkspace wake events to the sleep timer.
        // QueuePlayer lives in the Playback module and must not import AppKit,
        // so the wake subscription lives here in the app target.
        let sleepTimer = qp.sleepTimer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await sleepTimer.handleSystemWake() }
        }

        // Persist playback position on quit so it can be restored on next launch.
        registerTerminationObserver(player: qp)

        // Start scrobble worker once everything is wired up.
        Task { [scrobble] in await scrobble.start() }
    }

    // MARK: - Private helpers

    private static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "library.watchForChanges": true,
            "ui.windowMode.restoresLastMode": true,
            "appearance.colorScheme": "system",
            "appearance.accentColor": "system",
            "appearance.rowDensity": "regular",
            "advanced.logLevel": "info",
            "playback.rate": 1.0,
            "playback.gaplessPrerollSeconds": 5.0,
        ])
    }

    private struct ScrobbleParts {
        let service: ScrobbleService
        let viewModel: ScrobbleSettingsViewModel
    }

    private static func makeScrobble(database db: Database, log: AppLogger) -> ScrobbleParts {
        let credentials = Credentials()
        let adapter = CredentialsAdapter(store: credentials)
        let http: any HTTPClient = URLSession.shared
        var providers: [any ScrobbleProvider] = []
        if let cfg = LastFmConfig.fromBundle() {
            providers.append(LastFmProvider(config: cfg, http: http, credentials: adapter))
        } else {
            log.info("scrobble.lastfm.disabled", ["reason": "no api key in Info.plist"])
        }
        providers.append(ListenBrainzProvider(http: http, credentials: adapter))
        let repo = ScrobbleQueueRepository(database: db)
        let reachability = SystemReachability()
        let service = ScrobbleService(providers: providers, repository: repo, reachability: reachability)
        let viewModel = ScrobbleSettingsViewModel(service: service, credentials: adapter) { url in
            NSWorkspace.shared.open(url)
        }
        return ScrobbleParts(service: service, viewModel: viewModel)
    }
}

// MARK: - BocanCommands

/// Application menu commands.
///
/// Stored as plain `let` references (not `@ObservedObject`) so this struct's
/// `body` never re-evaluates due to observable publishes.  `BocanApp.body`
/// itself is also free of `@StateObject` subscriptions, meaning the menu bar
/// is only rebuilt on `showMenuBarExtra` changes — not on every selection or
/// playback tick.  Track-menu items are always enabled; actions guard
/// internally against empty selections.
private struct BocanCommands: Commands {
    let vm: LibraryViewModel
    let windowMode: WindowModeController
    let lyricsVM: LyricsViewModel
    let visualizerVM: VisualizerViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder to Library…") {
                Task { await self.vm.addFolderByPicker() }
            }
            .keyboardShortcut(KeyBindings.addFolder)

            Button("Add Files to Library…") {
                Task { await self.vm.addFilesByPicker() }
            }
            .keyboardShortcut(KeyBindings.addFiles)

            Divider()

            Button("Import Playlist…") {
                self.vm.isPlaylistImportSheetPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Playback") {
            Button("Play / Pause") {
                Task { await self.vm.nowPlaying.playPause() }
            }
            .keyboardShortcut(KeyBindings.playPause)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Show Lyrics") {
                self.lyricsVM.paneVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(self.visualizerVM.paneVisible ? "Hide Visualizer" : "Show Visualizer") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.visualizerVM.paneVisible.toggle()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Open Fullscreen Visualizer") {
                self.openWindow(id: "visualizer-fullscreen")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle Miniplayer") {
                self.windowMode.toggleMiniPlayer()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }

        CommandMenu("Track") {
            Button("Get Info") {
                self.vm.showTagEditorForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.getInfo)

            Button("Identify Track\u{2026}") {
                self.vm.showIdentifyTrackForCurrentSelection()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Reveal in Finder") {
                self.vm.revealSelectedInFinder()
            }
            .keyboardShortcut(KeyBindings.revealInFinder)

            Divider()

            Button("Love") {}
                .keyboardShortcut(KeyBindings.love)
                .disabled(true)
        }
    }
}

// MARK: - Helpers

/// Registers a `willTerminateNotification` observer that saves the current
/// playback position to `UserDefaults` before the process exits.
///
/// A `DispatchSemaphore` is used to block termination briefly while the async
/// save completes; the 2-second timeout prevents a hang on slow devices.
private func registerTerminationObserver(player: QueuePlayer) {
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: nil
    ) { _ in
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await player.savePositionForSuspend()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

// MARK: - InspectorWindowContent

/// Observes `LibraryViewModel` so the Track Info window reacts to `inspectorTrack`
/// changes at runtime (the `Window` scene builder itself does not re-evaluate on
/// `@Published` changes without this helper).
private struct InspectorWindowContent: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        if let track = vm.inspectorTrack {
            TrackInspectorPanel(track: track, database: self.vm.database)
        } else {
            Text("No track selected")
                .foregroundStyle(.secondary)
                .frame(minWidth: 360, minHeight: 420)
        }
    }
}
