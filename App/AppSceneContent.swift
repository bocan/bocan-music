import SwiftUI
import UI

// Concrete content views for the graph-backed windows. Wrapping each window's
// content in a named `View` (rather than an inline generic `GraphContent`
// closure in `BocanApp.body`) keeps the scene `body` cheap enough for the
// SwiftUI scene type-checker — the same reason the app uses concrete views
// throughout `body`. Each renders once the object graph is ready; the windows
// open on demand (post-launch), so the empty placeholder is never seen. (#276)

// MARK: - Track info

struct TrackInfoWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            TrackInfoPanel()
                .environmentObject(graph.libraryViewModel)
        }
    }
}

// MARK: - Settings

struct SettingsWindowContent: View {
    let model: AppModel
    @Binding var showMenuBarExtra: Bool
    var body: some View {
        GraphContent(model: self.model) { graph in
            SettingsScene(
                router: graph.settingsRouter,
                backupViewModel: graph.backupSettingsViewModel,
                scrobbleViewModel: graph.scrobbleSettingsViewModel,
                subsonicViewModel: graph.subsonicSettingsViewModel,
                phoneSyncViewModel: graph.phoneSyncSettingsViewModel
            )
            .environment(graph.dspViewModel)
            .environmentObject(graph.libraryViewModel)
            .environment(\.menuBarExtraEnabled, self.$showMenuBarExtra)
        }
    }
}

// MARK: - Visualizer

struct VisualizerWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            VisualizerFullscreenView(
                vm: graph.visualizerViewModel,
                nowPlayingVM: graph.libraryViewModel.nowPlaying
            )
        }
    }
}

// MARK: - Equaliser & DSP

struct DSPWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            DSPSheet(vm: graph.dspViewModel)
                .environmentObject(graph.libraryViewModel)
        }
    }
}

// MARK: - Mini player

struct MiniPlayerWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            MiniPlayerView(vm: graph.miniPlayerViewModel)
                .environmentObject(graph.windowMode)
                .environmentObject(graph.libraryViewModel)
                .environmentObject(graph.visualizerViewModel)
        }
    }
}

// MARK: - Menu bar

struct MenuBarWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            MenuBarExtraScene(vm: graph.libraryViewModel.nowPlaying)
        }
    }
}

// MARK: - Log console

struct LogConsoleWindowContent: View {
    let model: AppModel
    var body: some View {
        GraphContent(model: self.model) { graph in
            LogConsoleView(vm: graph.logConsoleViewModel)
        }
    }
}

#if DEBUG
    struct DebugAudioWindowContent: View {
        let model: AppModel
        var body: some View {
            GraphContent(model: self.model) { graph in
                DebugAudioView(engine: graph.engine)
            }
        }
    }
#endif

// MARK: - Commands

/// App command menus. The conditional lives here (not inline in `body`) so the
/// main window's `.commands` modifier stays a simple expression. Populated once
/// the graph is ready; until then the default menus show (the brief load).
struct AppCommands: Commands {
    let model: AppModel
    let updateController: UpdateController

    @CommandsBuilder
    var body: some Commands {
        if let graph = model.graph {
            BocanCommands(
                vm: graph.libraryViewModel,
                windowMode: graph.windowMode,
                lyricsVM: graph.lyricsViewModel,
                visualizerVM: graph.visualizerViewModel,
                settingsRouter: graph.settingsRouter,
                updateController: self.updateController
            )
        }
    }
}
