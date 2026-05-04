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
    private let routeManager = RouteManager(provider: CoreAudioOutputDeviceProvider())
    private let routeViewModel: RouteViewModel

    var body: some Scene {
        // MARK: Main window

        WindowGroup("Bòcan", id: "main") {
            BocanRootView(
                vm: self.libraryViewModel,
                lyricsVM: self.lyricsViewModel,
                visualizerVM: self.visualizerViewModel,
                routeVM: self.routeViewModel
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

        #if DEBUG
            // Phase 1 audit #14: debug-only manual playback window.  Opens a
            // separate scene whose sole purpose is to drive the AudioEngine
            // directly for codec / fade / seek triage.  Compiled out of Release.
            Window("Debug Audio", id: "debug-audio") {
                DebugAudioView(engine: self.engine)
            }
        #endif
    }

    // swiftlint:disable:next function_body_length
    init() {
        Self.registerDefaults()

        self.log.info("app.launched", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"])
        #if os(macOS)
            MetricKitListener.shared.start()
        #endif

        // Phase 4 audit C5: reconcile login-item registration with the
        // `general.launchAtLogin` preference, and observe the user default so
        // toggling it in Settings registers/unregisters the app immediately.
        LaunchAtLoginController.reconcileAtLaunch()
        Self.installLaunchAtLoginObserver()

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
        self.scrobbleService = scrobbleParts.service
        self.scrobbleSettingsViewModel = scrobbleParts.viewModel

        let qp = QueuePlayer(engine: eng, database: db, scrobbleSink: scrobbleParts.service)
        let scanner = LibraryScanner(database: db)

        self.database = db
        self.engine = eng
        self.player = qp

        let lvm = LibraryViewModel(database: db, engine: qp, scanner: scanner)
        self.libraryViewModel = lvm
        self.dspViewModel = DSPViewModel(
            engine: eng,
            presetStore: presetStore,
            queuePlayer: qp,
            assignmentRepo: DSPAssignmentRepository(database: db)
        )
        self.miniPlayerViewModel = MiniPlayerViewModel(nowPlaying: lvm.nowPlaying)
        self.windowMode = WindowModeController()
        self.dockTile = DockTileController()

        let lsvc = LyricsService(database: db, fetcher: LRClibClient())
        self.lyricsService = lsvc
        self.lyricsViewModel = LyricsViewModel(service: lsvc)
        self.visualizerViewModel = VisualizerViewModel(engine: eng)
        // Phase 15: AirPlay routing — `routeManager` is set at declaration.
        self.routeViewModel = Self.makeRouteViewModel(manager: self.routeManager)

        // Forward NSWorkspace wake events to the sleep timer + install the
        // engine-level pause-on-sleep / resume-on-wake / device-change wiring.
        // QueuePlayer lives in the Playback module and must not import AppKit,
        // so all NSWorkspace subscriptions live in the app target.
        Self.installSleepWakeAndDeviceChangeObservers(engine: eng, sleepTimer: qp.sleepTimer)

        // Phase 3 audit H1: re-open FSEvent streams after the system wakes;
        // FSEvents may stop firing reliably across long sleeps.
        Self.installLibraryWakeObserver(scanner: scanner)

        // Phase 3 audit M1: kick off the FSEvents watcher at app launch (gated on
        // the `library.watchForChanges` preference).  Without this, FSEvents stay
        // silent until the user navigates into the Library view, breaking the
        // "files appear without manual rescan" acceptance criterion when the user
        // lands on Now Playing or launches via the dock.
        Task { [weak lvm] in await lvm?.startOrStopWatcher() }

        // Persist playback position on quit so it can be restored on next launch.
        registerTerminationObserver(player: qp, database: db)

        // Phase 2 audit #6: opportunistic iCloud backup, gated on settings.
        Self.scheduleLaunchBackup(database: db)

        // Start scrobble worker once everything is wired up.
        Task { [scrobble = scrobbleParts.service] in await scrobble.start() }
    }

    // MARK: - Private helpers

    private static func installLibraryWakeObserver(scanner: LibraryScanner) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await scanner.restartWatcher() }
        }
    }

    /// Phase 4 audit C5: observer that mirrors the `general.launchAtLogin`
    /// preference into `SMAppService` registration so flipping the toggle in
    /// Settings registers / unregisters the login item without a relaunch.
    private static func installLaunchAtLoginObserver() {
        // The observer outlives the App struct (UserDefaults retains its
        // notification subscription).  Hold it in a static so multiple init
        // calls (e.g. SwiftUI previews) don't pile up redundant observers.
        if self.launchAtLoginObserver != nil { return }
        self.launchAtLoginObserver = LaunchAtLoginObserver()
    }

    /// Strong reference to the KVO observer.  Static so it survives the
    /// `App` struct being re-instantiated during SwiftUI scene rebuilds.
    private static var launchAtLoginObserver: LaunchAtLoginObserver?

    /// Phase 1 audit #6/#7/#8: pause-on-sleep, gated resume-on-wake, and
    /// default-output-device-change reconfiguration are wired here.  Pulled
    /// out of `init` to keep the initializer body within SwiftLint's length
    /// limit.
    private static func installSleepWakeAndDeviceChangeObservers(engine: AudioEngine, sleepTimer: SleepTimer) {
        // QueuePlayer wake-forwarding for the sleep timer.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await sleepTimer.handleSystemWake() }
        }

        // Spec: "Sleep/wake → pause on sleep; resume on wake **only if** we
        // were playing (configurable later, default no)."  Pausing on sleep
        // prevents the audible glitch produced when AVAudioEngine
        // reconfigures asynchronously after the lid closes.  Resume-on-wake
        // is gated on `playback.resumeOnWake` (defaults to false).
        let wasPlayingBox = _InitBox<Bool>()
        wasPlayingBox.value = false
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                wasPlayingBox.value = await engine.isPlaying
                await engine.pause()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            guard UserDefaults.standard.bool(forKey: "playback.resumeOnWake") else { return }
            guard wasPlayingBox.value == true else { return }
            Task { try? await engine.play() }
        }

        // Default-output-device change → reconfigure engine.  CoreAudio
        // listener fires on a HAL thread; AudioEngine hops onto its own
        // actor before touching AVFoundation state.
        Task { await engine.startObservingOutputDeviceChanges() }
    }

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
            "playback.resumeOnWake": false,
        ])
    }

    private struct ScrobbleParts {
        let service: ScrobbleService
        let viewModel: ScrobbleSettingsViewModel
    }

    @MainActor
    private static func makeRouteViewModel(manager: RouteManager) -> RouteViewModel {
        let viewModel = RouteViewModel(manager: manager)
        viewModel.start()
        return viewModel
    }

    /// Phase 2 audit #6: schedules an opportunistic iCloud Drive backup
    /// shortly after launch.  Detached so a stalled iCloud sign-in cannot
    /// delay UI; failures log only and never block startup.
    private static func scheduleLaunchBackup(database db: Database) {
        Task.detached { [db] in
            let settings = SettingsRepository(database: db)
            let enabled = await (try? settings.get(Bool.self, for: "backup.enabled")) ?? false
            guard enabled == true else { return }
            do {
                _ = try await BackupService(database: db).backupToiCloudIfAvailable()
            } catch {
                AppLogger.make(.app).error("backup.launch_failed", ["error": String(reflecting: error)])
            }
        }
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

// MARK: - Helpers
