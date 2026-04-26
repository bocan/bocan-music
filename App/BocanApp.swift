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

/// Handles `applicationShouldTerminateAfterLastWindowClosed` and `⌘W` hiding.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running when all windows are closed; Dock or menubar can reopen.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Dock click when no visible windows → reopen main window.
            sender.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// MARK: - BocanApp

@main
struct BocanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage("general.showMenuBarExtra") private var showMenuBarExtra = false

    private let log = AppLogger.make(.app)
    private let database: Database
    private let engine: AudioEngine
    private let player: QueuePlayer
    @StateObject private var libraryViewModel: LibraryViewModel
    @StateObject private var dspViewModel: DSPViewModel
    @StateObject private var miniPlayerViewModel: MiniPlayerViewModel
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

                Divider()

                Button("Mini Player") {
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

        // MARK: Settings

        Settings {
            SettingsScene()
                .environmentObject(self.dspViewModel)
        }

        // MARK: Track inspector

        Window("Track Info", id: "track-inspector") {
            InspectorWindowContent(vm: self.libraryViewModel)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)

        // MARK: Menu bar extra (opt-in via Settings > General)

        MenuBarExtra("Bòcan", systemImage: "music.note", isInserted: self.$showMenuBarExtra) {
            MenuBarExtraScene(vm: self.libraryViewModel.nowPlaying)
        }
        .menuBarExtraStyle(.window)
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
        _miniPlayerViewModel = StateObject(wrappedValue: MiniPlayerViewModel(nowPlaying: lvm.nowPlaying))
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
