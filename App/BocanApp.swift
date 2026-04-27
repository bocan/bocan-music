import AppKit
import AudioEngine
import Library
import Observability
import Persistence
import Playback
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
    @StateObject private var libraryViewModel: LibraryViewModel
    @StateObject private var dspViewModel: DSPViewModel
    // private let, not @StateObject: MiniPlayerViewModel.objectWillChange fires on every
    // playback tick (forwarded from NowPlayingViewModel).  @StateObject would subscribe
    // App.body to those ticks, rebuilding the Window menu 60× per second.  MiniPlayerView
    // observes the instance directly via @ObservedObject, so the mini player still updates.
    private let miniPlayerViewModel: MiniPlayerViewModel
    @StateObject private var windowMode: WindowModeController
    @StateObject private var dockTile: DockTileController

    var body: some Scene {
        // MARK: Main window

        WindowGroup("Bòcan", id: "main") {
            BocanRootView(vm: self.libraryViewModel)
                .environmentObject(self.dspViewModel)
                .environmentObject(self.windowMode)
                .onAppear { self.dockTile.start(observing: self.libraryViewModel.nowPlaying) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder to Library…") {
                    Task { await self.libraryViewModel.addFolderByPicker() }
                }
                .keyboardShortcut(KeyBindings.addFolder)

                Button("Add Files to Library…") {
                    Task { await self.libraryViewModel.addFilesByPicker() }
                }
                .keyboardShortcut(KeyBindings.addFiles)
            }

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    Task { await self.libraryViewModel.nowPlaying.playPause() }
                }
                .keyboardShortcut(KeyBindings.playPause)
            }

            CommandGroup(after: .windowArrangement) {
                Button("Toggle Miniplayer") {
                    self.windowMode.toggleMiniPlayer()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }

            CommandMenu("Track") {
                Button("Get Info") {
                    self.libraryViewModel.showTagEditorForCurrentSelection()
                }
                .keyboardShortcut(KeyBindings.getInfo)
                .disabled(!self.libraryViewModel.hasTrackSelection)

                Button("Identify Track\u{2026}") {
                    self.libraryViewModel.showIdentifyTrackForCurrentSelection()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!self.libraryViewModel.hasTrackSelection)

                Button("Reveal in Finder") {
                    self.libraryViewModel.revealSelectedInFinder()
                }
                .keyboardShortcut(KeyBindings.revealInFinder)
                .disabled(!self.libraryViewModel.hasTrackSelection)

                Divider()

                Button("Love") {}
                    .keyboardShortcut(KeyBindings.love)
                    .disabled(true)
            }
        }

        // MARK: Mini player

        MiniPlayerWindow(vm: self.miniPlayerViewModel)
            .environmentObject(self.windowMode)
            .environmentObject(self.libraryViewModel)

        // MARK: Settings

        Settings {
            SettingsScene()
                .environmentObject(self.dspViewModel)
                .environment(\.menuBarExtraEnabled, self.$showMenuBarExtra)
        }

        // MARK: Track inspector

        Window("Track Info", id: "track-inspector") {
            InspectorWindowContent(vm: self.libraryViewModel)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)

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

        let eng = AudioEngine()
        let qp = QueuePlayer(engine: eng, database: db)
        let scanner = LibraryScanner(database: db)

        self.database = db
        self.engine = eng
        self.player = qp

        let lvm = LibraryViewModel(database: db, engine: qp, scanner: scanner)
        _libraryViewModel = StateObject(wrappedValue: lvm)
        _dspViewModel = StateObject(wrappedValue: DSPViewModel(engine: eng))
        self.miniPlayerViewModel = MiniPlayerViewModel(nowPlaying: lvm.nowPlaying)
        _windowMode = StateObject(wrappedValue: WindowModeController())
        _dockTile = StateObject(wrappedValue: DockTileController())

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
