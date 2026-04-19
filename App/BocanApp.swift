import AudioEngine
import Library
import Observability
import Persistence
import Playback
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

            CommandMenu("Track") {
                Button("Get Info") {
                    self.libraryViewModel.openInspectorWindow?()
                }
                .keyboardShortcut(KeyBindings.getInfo)
                .disabled(self.libraryViewModel.inspectorTrack == nil)

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

        Window("Track Info", id: "track-inspector") {
            Group {
                if let track = self.libraryViewModel.inspectorTrack {
                    TrackInspectorPanel(track: track)
                } else {
                    Text("No track selected")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 380, minHeight: 340)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
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
        guard let db = box.value else {
            fatalError("Database initialisation completed without a value")
        }

        let eng = AudioEngine()
        let player = QueuePlayer(engine: eng, database: db)
        let scanner = LibraryScanner(database: db)
        self.database = db
        self.engine = eng
        self.libraryViewModel = LibraryViewModel(database: db, engine: player, scanner: scanner)
    }
}
