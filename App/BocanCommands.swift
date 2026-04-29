import Library
import SwiftUI
import UI

// MARK: - BocanCommands

/// Application menu commands.
///
/// Stored as plain `let` references (not `@ObservedObject`) so this struct's
/// `body` never re-evaluates due to observable publishes.  `BocanApp.body`
/// itself is also free of `@StateObject` subscriptions, meaning the menu bar
/// is only rebuilt on `showMenuBarExtra` changes — not on every selection or
/// playback tick.  Track-menu items are always enabled; actions guard
/// internally against empty selections.
struct BocanCommands: Commands {
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

            // Phase 3 audit M2: Quick / Full rescan entry-points for the File
            // menu so users aren't limited to per-track right-click "Re-scan File".
            // ⌘R is reserved for "Reveal in Finder" (see KeyBindings.revealInFinder)
            // and ⌘⇧R is used by TracksView's "Clear Sort", so we use ⌥-modifiers.
            Button("Quick Rescan Library") {
                self.vm.rescanLibrary(mode: .quick)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(self.vm.isScanning)

            Button("Full Rescan Library") {
                self.vm.rescanLibrary(mode: .full)
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            .disabled(self.vm.isScanning)

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
