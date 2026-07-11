// swiftlint:disable file_length
import AppKit
import AudioEngine
import Library
import Observability
import Persistence
import Playback
import Podcasts
import Scrobble
import Subsonic
import SwiftUI
import SyncServer
import UI
import UserNotifications

/// Small mutable `Sendable` box used to share a value across a notification
/// closure / `Task` boundary (e.g. the wake/sleep `wasPlaying` flag). Access is
/// effectively serialised by the main-actor notification callbacks that use it,
/// so `@unchecked` is safe here.
private final class _InitBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

// MARK: - AppDelegate

/// Handles `applicationShouldTerminateAfterLastWindowClosed`, `⌘W` hiding,
/// quit-guard confirmation, and `UNUserNotificationCenter` delegate callbacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // MARK: Quit-guard references

    /// Set once from `BocanApp.init()` so `applicationShouldTerminate` can
    /// inspect live scan state without importing UI types into AppKit callbacks.
    var libraryViewModel: LibraryViewModel?
    var dspViewModel: DSPViewModel?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        // Register as the notification delegate early so tap-to-foreground works.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Intercepts ⌘Q when a scan or ReplayGain analysis is active.
    ///
    /// Returns `.terminateLater` and shows a confirmation alert; the alert
    /// calls `NSApp.reply(toApplicationShouldTerminate:)` when dismissed so
    /// AppKit can proceed or cancel the quit.  Returns `.terminateNow`
    /// immediately when nothing is running so normal quits are unaffected.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let isInitialScan = self.libraryViewModel?.isInitialScan == true
        let isScanning = isInitialScan || self.libraryViewModel?.isScanning == true
        let isAnalyzing = self.dspViewModel?.isAnalyzing == true

        guard isScanning || isAnalyzing else { return .terminateNow }

        let informativeText = if isInitialScan {
            "Your music library is being built for the first time. "
                + "Quitting now will leave it incomplete — you may need to rescan when you relaunch."
        } else if isScanning {
            "A library scan is in progress. "
                + "Quitting now may leave recently added files out of your library."
        } else {
            "ReplayGain analysis is in progress. "
                + "Volume normalisation data for the current batch will be lost if you quit now."
        }

        let alert = NSAlert()
        alert.messageText = "Quit Bòcan?"
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        // Task defers the modal until after applicationShouldTerminate returns
        // .terminateLater; otherwise the nested run loop causes AppKit re-entrancy.
        Task { @MainActor in
            let reply = alert.runModal() == .alertFirstButtonReturn
            NSApp.reply(toApplicationShouldTerminate: reply)
        }

        return .terminateLater
    }

    /// Called by AppKit immediately before the process exits.
    func applicationWillTerminate(_: Notification) {
        LaunchSanity.shared.markCleanExit()
        SingleInstance.shared.stop()
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

    /// Handles files dragged onto the Dock icon or opened via "Open With…".
    ///
    /// Forwards audio files and playlists to `LibraryViewModel.addDroppedURLs`.
    func application(_: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty, let lvm = self.libraryViewModel else { return }
        Task { await lvm.addDroppedURLs(urls) }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tapping a track-change banner brings the app to the foreground.
    /// `nonisolated` because UNUserNotificationCenter may invoke this off the main thread.
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

    /// Database-independent, so built eagerly and used by the About window and
    /// the command menus even while the library is still loading.
    private let updateController = UpdateController()

    /// Owns the asynchronously-built object graph (database, engine, player, view
    /// models). The DB is opened and the graph wired off the main thread in
    /// `AppModel.bootstrap`, so the window shell renders immediately instead of
    /// blocking `init` on the DB open. See #276. `@Observable`, so reading
    /// `model.graph` re-evaluates `body` exactly once — when the graph becomes
    /// ready — without subscribing to every downstream change.
    @State private var model = AppModel()

    /// The scene tree is kept flat and (mostly) unconditional: gating whole
    /// scenes on `model.graph` overran the SwiftUI scene type-checker (the same
    /// limit the RootView extraction worked around). Instead, the main window
    /// shows a loading shell via `AppRootGate`, and the graph-backed secondary
    /// windows render their content through `GraphContent` once the graph is
    /// ready (they only open post-launch, so the placeholder is never seen).
    /// Only `MiniPlayerWindow` — a custom `Scene` that takes its view model at
    /// init — must be declared conditionally.
    var body: some Scene {
        // MARK: Main window

        WindowGroup("Bòcan", id: "main") {
            AppRootGate(model: self.model, appDelegate: self.appDelegate)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: self.model, updateController: self.updateController) }

        // MARK: About / Help / Notices (database-independent)

        Window("About Bòcan", id: "about") {
            AboutView(
                onCheckForUpdates: { self.updateController.checkForUpdates() },
                canCheckForUpdates: self.updateController.canCheckForUpdates
            )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 520)
        .restorationBehavior(.disabled)

        Window("Bòcan Help", id: "bocan-help") {
            HelpWindowView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 540)
        .restorationBehavior(.disabled)

        Window("Notices \u{26} Licences", id: "notices") {
            NoticesWindowView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 560)
        .restorationBehavior(.disabled)

        // MARK: Track info panel

        Window("Track Info", id: "track-info") {
            TrackInfoWindowContent(model: self.model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        // MARK: Settings

        Settings {
            SettingsWindowContent(model: self.model, showMenuBarExtra: self.$showMenuBarExtra)
        }

        // MARK: Visualizer fullscreen

        Window("Visualizer", id: "visualizer-fullscreen") {
            VisualizerWindowContent(model: self.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)

        // MARK: Equaliser & DSP panel

        Window("Equaliser & DSP", id: "dsp") {
            DSPWindowContent(model: self.model)
        }
        .defaultSize(width: 600, height: 520)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .keyboardShortcut(KeyBindings.showEQPanel)

        // MARK: Menu bar widget

        // `isPlaying` / `isPaused` give property-level granularity, so this
        // re-evaluates at most twice per track transition.
        let np = self.model.graph?.libraryViewModel.nowPlaying
        let menuBarLabel: String = np?.isPlaying == true ? "Bòcan — Playing"
            : (np?.isPaused == true ? "Bòcan — Paused" : "Bòcan")
        let menuBarIcon: String = np?.isPlaying == true ? "music.note.list" : "music.note"
        MenuBarExtra(menuBarLabel, systemImage: menuBarIcon, isInserted: self.$showMenuBarExtra) {
            MenuBarWindowContent(model: self.model)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: self.showMenuBarExtra) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "general.showMenuBarExtra")
        }

        // MARK: Mini player

        // Inlined (rather than the UI module's `MiniPlayerWindow` scene) so the
        // window is unconditional and its content is graph-gated, keeping the
        // scene list flat. `.commandsRemoved()` strips SwiftUI's auto-injected
        // "Mini Player" Window-menu item, matching the old MiniPlayerWindow.
        Window("Mini Player", id: "mini") {
            MiniPlayerWindowContent(model: self.model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 72)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        // MARK: Log console

        Window("Log Console", id: "log-console") {
            LogConsoleWindowContent(model: self.model)
        }
        .defaultSize(width: 900, height: 520)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        #if DEBUG
            // Phase 1 audit #14: debug-only manual playback window for codec /
            // fade / seek triage. Compiled out of Release.
            Window("Debug Audio", id: "debug-audio") {
                DebugAudioWindowContent(model: self.model)
            }
        #endif
    }

    init() {
        // Detect unclean exit from the previous session (crash / force-quit).
        // Must run before any UI is constructed so the recovery banner state
        // is in UserDefaults before SwiftUI reads it via @AppStorage.
        LaunchSanity.shared.markRunning()

        // Enforce single-instance *before* any subsystem is initialised.
        // If another instance is already running this call exits immediately.
        SingleInstance.shared.start()

        Self.registerDefaults()

        // "scrobble.showRecentSheet" is a transient menu-to-strip signal
        // (BocanCommands sets it, NowPlayingStrip presents the sheet on it).
        // Clear any value persisted by a previous session so the sheet does
        // not reopen at launch.
        UserDefaults.standard.removeObject(forKey: "scrobble.showRecentSheet")

        // Phase 20: apply the persisted capture preference before the first log
        // line is emitted so the console backfills from the very start of this session.
        LogStore.shared.isCaptureEnabled = UserDefaults.standard.bool(forKey: "console.captureEnabled")

        self.log.info("app.launched", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"])
        #if os(macOS)
            MetricKitListener.shared.start()
        #endif

        // Phase 4 audit C5: reconcile login-item registration with the
        // `general.launchAtLogin` preference, and observe the user default so
        // toggling it in Settings registers/unregisters the app immediately.
        LaunchAtLoginController.reconcileAtLaunch()
        Self.installLaunchAtLoginObserver()

        // #276: the database is opened (async) and the object graph wired in
        // `AppModel.bootstrap`, kicked off from the main window's `.task`. This
        // keeps the formerly main-thread-blocking DB open off the synchronous
        // launch path, so the window shell renders immediately. Only the cheap,
        // UI-free pre-flight above runs here.
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
            "appearance.rowDensity": "spacious",
            "advanced.logLevel": "info",
            "playback.rate": 1.0,
            "playback.gaplessPrerollSeconds": 5.0,
            "playback.resumeOnWake": false,
            "general.showAlbumArtInDock": true,
            "general.showPlaybackBadge": true,
            "general.showDockProgress": true,
            "console.captureEnabled": true,
            "sync.enabled": false,
        ])
    }

    private struct ScrobbleParts {
        let service: ScrobbleService
        let viewModel: ScrobbleSettingsViewModel
    }

    /// Schedules launch-time backups (iCloud + local), each gated on its own setting.
    private static func scheduleLaunchBackup(database db: Database) {
        Task.detached { [db] in
            let settings = SettingsRepository(database: db)
            let service = BackupService(database: db)
            let log = AppLogger.make(.app)
            if await (try? settings.get(Bool.self, for: "backup.enabled")) ?? false {
                do {
                    _ = try await service.backupToiCloudIfAvailable()
                } catch {
                    log.error("backup.icloud.launch_failed", ["error": String(reflecting: error)])
                }
            }
            if await (try? settings.get(Bool.self, for: "backup.local.enabled")) ?? true {
                let keep = await (try? settings.get(Int.self, for: "backup.local.keepCount")) ?? 5
                do {
                    _ = try await service.backupToLocal(keepLast: keep)
                } catch {
                    log.error("backup.local.launch_failed", ["error": String(reflecting: error)])
                }
            }
        }
    }

    private static func makeScrobble(
        database db: Database,
        log: AppLogger,
        subsonicDelivery: any SubsonicScrobbleDelivering
    ) -> ScrobbleParts {
        let credentials = Credentials()
        let adapter = CredentialsAdapter(store: credentials)
        // Module-qualified: both Scrobble and Podcasts export an `HTTPClient`
        // protocol, so the bare name is ambiguous now that App imports Podcasts.
        let http: any Scrobble.HTTPClient = URLSession.shared
        var providers: [any ScrobbleProvider] = []
        if let cfg = LastFmConfig.fromBundle() {
            providers.append(LastFmProvider(config: cfg, http: http, credentials: adapter))
        } else {
            log.info("scrobble.lastfm.disabled", ["reason": "no api key in Info.plist"])
        }
        providers.append(ListenBrainzProvider(http: http, credentials: adapter))
        providers.append(RockskyProvider(http: http, credentials: adapter))
        providers.append(SubsonicScrobbleProvider(delivery: subsonicDelivery))
        let repo = ScrobbleQueueRepository(database: db)
        let reachability = SystemReachability()
        let service = ScrobbleService(providers: providers, repository: repo, reachability: reachability)
        let viewModel = ScrobbleSettingsViewModel(service: service, credentials: adapter) { url in
            NSWorkspace.shared.open(url)
        }
        return ScrobbleParts(service: service, viewModel: viewModel)
    }
}

// MARK: - Object graph

/// The fully-wired application object graph. Built once the database is open
/// (off the synchronous launch path) and held for the app's lifetime by
/// `AppModel`. Everything here was previously a `private let` on `BocanApp`,
/// constructed synchronously in `init` behind the blocking DB open (#276).
@MainActor
struct AppGraph {
    let database: Database
    let engine: AudioEngine
    let player: QueuePlayer
    let libraryViewModel: LibraryViewModel
    let dspViewModel: DSPViewModel
    let miniPlayerViewModel: MiniPlayerViewModel
    let windowMode: WindowModeController
    let dockTile: DockTileController
    let lyricsService: LyricsService
    let lyricsViewModel: LyricsViewModel
    let visualizerViewModel: VisualizerViewModel
    let scrobbleService: ScrobbleService
    let scrobbleSettingsViewModel: ScrobbleSettingsViewModel
    let backupSettingsViewModel: BackupSettingsViewModel
    let subsonicStore: SubsonicServerStore
    let subsonicService: SubsonicService
    let subsonicSettingsViewModel: SubsonicSettingsViewModel
    /// Shared deep-link navigation for the Settings scene (#305).
    let settingsRouter: SettingsRouter
    let logConsoleViewModel: LogConsoleViewModel
    /// Phase 22-7: the Phone Sync server (off unless `sync.enabled`).
    let syncServer: SyncServer
    /// Phase 22-8: the Settings -> Phone Sync view model.
    let phoneSyncSettingsViewModel: PhoneSyncViewModel
}

// MARK: - AppModel

/// Owns the asynchronous launch bootstrap. `BocanApp` holds this in `@State`;
/// the main window renders a loading shell until `graph` is populated.
///
/// `@Observable` gives property-level granularity, so `body` re-evaluates once
/// when `graph` (or `failed`) changes, not on every downstream mutation.
@MainActor
@Observable
final class AppModel {
    private(set) var graph: AppGraph?
    /// `true` if the database could not be opened. Surfaced as `LaunchErrorView`
    /// instead of the previous `fatalError` crash.
    private(set) var failed = false
    private var started = false

    private let log = AppLogger.make(.app)

    /// Opens the database off the main thread and wires the object graph.
    /// Idempotent: only the first call does work (the main window's `.task` may
    /// run more than once across the window's lifetime).
    func bootstrap(appDelegate: AppDelegate) async {
        guard !self.started else { return }
        self.started = true
        let endBootstrap = Telemetry.timer("app.bootstrap")
        defer { endBootstrap() }

        let start = Date()
        do {
            let db = try await Database(location: .application)
            self.graph = BocanApp.buildGraph(database: db, appDelegate: appDelegate)
            self.log.info("app.bootstrap.ready", ["ms": -start.timeIntervalSinceNow * 1000])
        } catch {
            self.log.error("app.bootstrap.dbOpenFailed", ["error": String(reflecting: error)])
            self.failed = true
        }
    }
}

// MARK: - Object-graph construction

extension BocanApp {
    // swiftlint:disable function_body_length
    /// Builds and wires the full object graph once the database is open. Runs on
    /// the main actor (the view models are main-actor isolated) but off the
    /// synchronous launch path, so it no longer blocks first paint. Lifted
    /// verbatim from the old `init` body, with `self.x = y` assignments replaced
    /// by locals returned in the `AppGraph`. See #276.
    @MainActor
    static func buildGraph(database db: Database, appDelegate: AppDelegate) -> AppGraph {
        let log = AppLogger.make(.app)
        let endBuildGraph = Telemetry.timer("app.buildGraph")
        defer { endBuildGraph() }
        let presetStore = PresetStore()
        let eng = AudioEngine(presets: presetStore)

        // Phase 19: Subsonic infra is built before the scrobble service so
        // its provider can write through to the active Subsonic servers.
        let subsonicRepo = SubsonicServerRepository(database: db)
        let subsonicStore = SubsonicServerStore(repository: subsonicRepo)
        let subsonicService = SubsonicService(store: subsonicStore)
        let subsonicAnnotations = SubsonicAnnotations(service: subsonicService)
        let subsonicMonitor = SubsonicConnectionMonitor(service: subsonicService)
        let subsonicListing = SubsonicStoreSidebarListing(store: subsonicStore, service: subsonicService)

        // Build the scrobble service before the player so the sink can be wired in.
        let scrobbleParts = Self.makeScrobble(
            database: db,
            log: log,
            subsonicDelivery: SubsonicScrobbleDelivery(service: subsonicService, store: subsonicStore)
        )
        let backupSettingsViewModel = BackupSettingsViewModel(database: db)

        // Phase 19: build the Subsonic stream cache (and resolver) so QueuePlayer
        // can turn a `.subsonic` PlayableSource into a local file URL the engine
        // can decode. Cache lives under the user's Caches directory so macOS
        // can reclaim space under pressure.
        let cachesRoot = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let streamCacheDir = cachesRoot
            .appendingPathComponent("io.cloudcauldron.bocan", isDirectory: true)
            .appendingPathComponent("SubsonicStreams", isDirectory: true)
        let subsonicStreamCache: SubsonicStreamCache? = try? SubsonicStreamCache(
            configuration: SubsonicStreamCache.Configuration(rootDirectory: streamCacheDir),
            loader: RemoteTrackLoader(transport: URLSessionHTTPTransport())
        )
        let subsonicStreamResolver: SubsonicStreamResolver? = subsonicStreamCache.map {
            SubsonicStreamResolver(cache: $0, service: subsonicService, store: subsonicStore)
        }

        // Phase 21-5: build a PodcastService and adapt it to the player's
        // PodcastEpisodeResolving seam so .podcast queue items can play,
        // resume, write back position, and mark played.
        // Phase 21-7: promotes this service into the graph for the Podcasts UI
        // and wires the FeedRefreshScheduler background task.
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)
        let podcastService = PodcastService(
            podcastRepo: PodcastRepository(database: db),
            episodeRepo: episodeRepo,
            stateRepo: stateRepo,
            transcriptRepo: TranscriptRepository(database: db),
            artwork: PodcastArtworkCache()
        )
        let podcastResolver = AppPodcastResolver(service: podcastService)
        let podcastDownloads = EpisodeDownloadManager(
            stateRepo: stateRepo,
            episodeRepo: episodeRepo
        )
        let feedRefreshScheduler = FeedRefreshScheduler(service: podcastService)

        let qp = QueuePlayer(
            engine: eng,
            database: db,
            scrobbleSink: scrobbleParts.service,
            subsonicResolver: subsonicStreamResolver,
            podcastResolver: podcastResolver
        )
        let scanner = LibraryScanner(database: db)

        let podcastActions = AppPodcastActions(
            service: podcastService,
            player: qp,
            downloads: podcastDownloads
        )
        let piCredentials = PodcastIndexCredentials(
            apiKey: Bundle.main.object(forInfoDictionaryKey: "BocanPodcastIndexApiKey") as? String ?? "",
            apiSecret: Bundle.main.object(forInfoDictionaryKey: "BocanPodcastIndexApiSecret") as? String ?? ""
        )
        let podcastSearch = AppPodcastSearch(
            searchService: PodcastSearchService(
                podcastIndex: piCredentials.isConfigured ? PodcastIndexClient(credentials: piCredentials) : nil,
                itunes: ITunesSearchClient()
            ),
            fetcher: FeedFetcher(),
            parser: FeedParser(),
            podcastRepo: PodcastRepository(database: db)
        )
        let lvm = LibraryViewModel(
            database: db,
            engine: qp,
            scanner: scanner,
            scrobbleRepository: scrobbleParts.service.queueRepository,
            scrobbleService: scrobbleParts.service,
            subsonicSidebarListing: subsonicListing,
            subsonicDataSource: subsonicService,
            subsonicCoverArtProvider: SubsonicCoverArtProvider(service: subsonicService),
            subsonicMetadataCache: SubsonicRepositoryMetadataCache(repository: subsonicRepo),
            subsonicAnnotationDelivery: subsonicAnnotations,
            subsonicCapabilityObserver: SubsonicCapabilityObserver(service: subsonicService),
            subsonicConnectionObserver: SubsonicMonitorConnectionObserver(monitor: subsonicMonitor),
            podcastLibrary: podcastService,
            podcastActions: podcastActions,
            podcastSearch: podcastSearch,
            podcastTranscript: podcastService
        )
        // Wire auto-download, then start the background feed refresh loop. Every
        // successful refresh that finds new episodes calls the observer, which
        // enqueues the newest N (podcasts.autoDownloadCount, default 3) for shows
        // that have auto-download enabled. Setting the observer before the
        // scheduler starts means the very first background refresh already honours
        // it. Phase 21-7 spec: start() is called once at launch and is idempotent
        // so wake-notifications can also call it without duplicating the loop.
        Task.detached(priority: .background) { [episodeRepo, stateRepo, podcastDownloads, db] in
            await podcastService.setNewEpisodesObserver { podcastID, newGUIDs in
                let newestN = UserDefaults.standard.object(forKey: "podcasts.autoDownloadCount") as? Int ?? 3
                let coordinator = AutoDownloadCoordinator(
                    podcastRepo: PodcastRepository(database: db),
                    episodeRepo: episodeRepo,
                    stateRepo: stateRepo,
                    manager: podcastDownloads,
                    newestN: newestN
                )
                await coordinator.handleRefresh(
                    podcastID: podcastID,
                    outcome: RefreshOutcome(
                        notModified: false,
                        newEpisodeCount: newGUIDs.count,
                        totalEpisodeCount: 0,
                        newEpisodeGUIDs: newGUIDs
                    )
                )
            }
            await feedRefreshScheduler.start()
        }
        // Wire the Subsonic bootstrap so RootView.task can pre-load clients
        // before restoring navigation state, eliminating the startup race that
        // caused "Couldn't load songs / No server with id …" when the last
        // selected destination was a Subsonic view.
        lvm.subsonicBootstrap = { [subsonicService, weak lvm] in
            try? await subsonicService.reloadClients()
            await lvm?.reloadSubsonicServers()
        }
        let subsonicSettingsViewModel = SubsonicSettingsViewModel(
            store: subsonicStore,
            service: subsonicService,
            monitor: subsonicMonitor
        ) { [weak lvm] in await lvm?.reloadSubsonicServers() }
        let dspViewModel = DSPViewModel(
            engine: eng,
            presetStore: presetStore,
            queuePlayer: qp,
            assignmentRepo: DSPAssignmentRepository(database: db)
        )
        let miniPlayerViewModel = MiniPlayerViewModel(nowPlaying: lvm.nowPlaying)
        let windowMode = WindowModeController()
        let dockTile = DockTileController()

        // The edit service routes "Embed in file" writes through the full edit
        // pipeline (scoping, atomic write, backup ring, mtime stamping) instead
        // of the legacy direct TagWriter path.
        let lsvc = LyricsService(
            database: db,
            fetcher: LRClibClient(),
            editService: lvm.metadataEditService
        )
        let lyricsViewModel = LyricsViewModel(service: lsvc)
        let visualizerViewModel = VisualizerViewModel(engine: eng)

        // Wire quit-guard references so AppDelegate can check live background-work
        // state in applicationShouldTerminate without importing UI into AppKit code.
        appDelegate.libraryViewModel = lvm
        appDelegate.dspViewModel = dspViewModel

        // Forward NSWorkspace wake events to the sleep timer + install the
        // engine-level pause-on-sleep / resume-on-wake / device-change wiring.
        // QueuePlayer lives in the Playback module and must not import AppKit,
        // so all NSWorkspace subscriptions live in the app target.
        Self.installSleepWakeAndDeviceChangeObservers(engine: eng, sleepTimer: qp.sleepTimer)

        // Phase 3 audit H1: re-open FSEvent streams after the system wakes.
        Self.installLibraryWakeObserver(scanner: scanner)

        // Phase 3 audit M1: kick off the FSEvents watcher at app launch (gated on
        // the `library.watchForChanges` preference).
        Task { [weak lvm] in await lvm?.startOrStopWatcher() }

        // Persist playback position on quit so it can be restored on next launch.
        registerTerminationObserver(player: qp, database: db)

        // Phase 22-7: the Phone Sync server. Constructed unconditionally so the
        // Settings toggle (22-8) can start/stop it, but only started here when
        // `sync.enabled` is on (default off). `serverName` is injected as a
        // closure so SyncServer never imports AppKit. `downloadRoot: nil` matches
        // the EpisodeDownloadManager default the manifest and file serving read.
        let syncServerName: @Sendable () -> String = { Host.current().localizedName ?? "Bòcan" }
        let phoneSyncBridge = PhoneSyncPairingBridge()
        let syncServer = SyncServer(
            database: db,
            identity: ServerIdentity(),
            ui: phoneSyncBridge,
            serverName: syncServerName
        )
        // Phase 22-8: the Settings view model, wired over the server via the
        // control seam; the relay bridge forwards the pairing ceremony to it.
        let phoneSyncController = PhoneSyncController(
            server: syncServer,
            profileRepository: SyncProfileRepository(database: db),
            playlistRepository: PlaylistRepository(database: db),
            manifestBuilder: ManifestBuilder(database: db)
        )
        let phoneSyncViewModel = PhoneSyncViewModel(control: phoneSyncController)
        phoneSyncBridge.receiver = phoneSyncViewModel
        Self.installSyncServerLifecycleObservers(syncServer: syncServer)
        if UserDefaults.standard.bool(forKey: "sync.enabled") {
            Task { [syncServer] in
                do {
                    try await syncServer.start()
                } catch {
                    log.error("sync.start.failed", ["error": String(reflecting: error)])
                }
            }
        }

        Self.scheduleLaunchBackup(database: db)

        // Start scrobble worker once everything is wired up.
        Task { [scrobble = scrobbleParts.service] in await scrobble.start() }

        // Phase 19: finish Subsonic hydration. migrateOrphans and startMonitoring
        // must run here; reloadClients / reloadSubsonicServers are idempotent
        // catch-alls also run by bootstrapSubsonic via RootView.task.
        Task { [subsonicStore, subsonicService, subsonicMonitor, subsonicRepo, weak lvm] in
            // Prune Keychain items whose server row no longer exists, then build clients.
            try? await subsonicStore.migrateOrphans()
            try? await subsonicService.reloadClients()
            await lvm?.reloadSubsonicServers()
            // Phase 19 step 17: kick off the ping/back-off loop for every
            // persisted server so the sidebar status dots become live as
            // soon as the user finishes launching.
            let servers = await (try? subsonicStore.fetchAll()) ?? []
            for server in servers {
                await subsonicMonitor.startMonitoring(serverID: server.id)
            }
            // Refresh capabilities on launch so the legacy-core probe
            // (Internet Radio / Podcasts / Bookmarks) runs and the sidebar
            // reflects whatever the server actually supports today.
            await withTaskGroup(of: Void.self) { group in
                for server in servers {
                    group.addTask {
                        _ = try? await subsonicService.loadCapabilities(serverID: server.id)
                    }
                }
            }
            // Spec: prune metadata-cache entries older than 7 days once on launch.
            try? await subsonicRepo.pruneStaleCache()
        }

        return AppGraph(
            database: db,
            engine: eng,
            player: qp,
            libraryViewModel: lvm,
            dspViewModel: dspViewModel,
            miniPlayerViewModel: miniPlayerViewModel,
            windowMode: windowMode,
            dockTile: dockTile,
            lyricsService: lsvc,
            lyricsViewModel: lyricsViewModel,
            visualizerViewModel: visualizerViewModel,
            scrobbleService: scrobbleParts.service,
            scrobbleSettingsViewModel: scrobbleParts.viewModel,
            backupSettingsViewModel: backupSettingsViewModel,
            subsonicStore: subsonicStore,
            subsonicService: subsonicService,
            subsonicSettingsViewModel: subsonicSettingsViewModel,
            settingsRouter: SettingsRouter(),
            logConsoleViewModel: LogConsoleViewModel(),
            syncServer: syncServer,
            phoneSyncSettingsViewModel: phoneSyncViewModel
        )
    }

    // swiftlint:enable function_body_length

    /// Phase 22-7: re-advertise Phone Sync after the system wakes (the listener
    /// may drop its Bonjour service across sleep), and withdraw it cleanly on
    /// quit. Only fires effect when the server is running; a no-op while off.
    private static func installSyncServerLifecycleObservers(syncServer: SyncServer) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await syncServer.reAdvertise() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await syncServer.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }
}
