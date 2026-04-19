import AudioEngine
import Observability
import Persistence
import SwiftUI
import UI

/// Sendable wrapper used only during synchronous app init to transfer the
/// Database actor across the Task.detached boundary.  The semaphore enforces
/// strict single-writer / single-reader ordering, so @unchecked is safe here.
private final class _InitBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

@main
struct BocanApp: App {
    private let log = AppLogger.make(.app)
    private let database: Database
    private let engine: AudioEngine
    private let libraryViewModel: LibraryViewModel

    var body: some Scene {
        WindowGroup {
            BocanRootView(vm: self.libraryViewModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    Task { await self.libraryViewModel.nowPlaying.playPause() }
                }
                .keyboardShortcut(KeyBindings.playPause)
            }

            CommandMenu("Track") {
                Button("Get Info") {}
                    .keyboardShortcut(KeyBindings.getInfo)
                    .disabled(true) // TODO(phase-8)

                Button("Reveal in Finder") {
                    // Forwarded to TracksView selection
                }
                .keyboardShortcut(KeyBindings.revealInFinder)
                .disabled(true) // handled per-view

                Divider()

                Button("Love") {}
                    .keyboardShortcut(KeyBindings.love)
                    .disabled(true) // TODO(phase-8)
            }
        }
    }

    init() {
        self.log.info("app.launched", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"])
        #if os(macOS)
            MetricKitListener.shared.start()
        #endif

        // Initialise the database synchronously on the calling thread.
        // Task.detached runs off the MainActor so the semaphore can be signalled
        // while the main thread waits.  _InitBox transfers the result safely across
        // the Task boundary without triggering Swift 6 data-race diagnostics.
        let semaphore = DispatchSemaphore(value: 0)
        let box = _InitBox<Database>()
        Task.detached {
            do {
                box.value = try await Database(location: .application)
            } catch {
                fatalError("Failed to open application database: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        let db = box.value!

        let eng = AudioEngine()
        self.database = db
        self.engine = eng
        self.libraryViewModel = LibraryViewModel(database: db, engine: eng)
    }
}
