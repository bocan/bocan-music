import AudioEngine
import Observability
import Persistence
import SwiftUI
import UI

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

        // Initialise the database synchronously on the calling thread
        // (Database.init is async so we use a Task + semaphore here)
        let semaphore = DispatchSemaphore(value: 0)
        var db: Database!
        Task {
            db = try! await Database(location: .application)
            semaphore.signal()
        }
        semaphore.wait()

        let eng = AudioEngine()
        self.database = db
        self.engine = eng
        self.libraryViewModel = LibraryViewModel(database: db, engine: eng)
    }
}
