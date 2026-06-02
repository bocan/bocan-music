import SwiftUI
import UI

// MARK: - AppRootGate

/// Content of the main window. Renders immediately at launch and shows a
/// lightweight loading state until `AppModel.bootstrap` finishes opening the
/// database and wiring the object graph off the main thread (#276). The
/// bootstrap is kicked off here via `.task` so the window shell is on screen
/// before the (formerly main-thread-blocking) DB open completes.
struct AppRootGate: View {
    let model: AppModel
    let appDelegate: AppDelegate

    var body: some View {
        Group {
            if let graph = model.graph {
                BocanRootView(
                    vm: graph.libraryViewModel,
                    lyricsVM: graph.lyricsViewModel,
                    visualizerVM: graph.visualizerViewModel,
                    scrobbleSettingsVM: graph.scrobbleSettingsViewModel
                )
                .environment(graph.dspViewModel)
                .environment(\.settingsRouter, graph.settingsRouter)
                .environmentObject(graph.windowMode)
                .environmentObject(graph.lyricsViewModel)
                .onAppear { graph.dockTile.start(observing: graph.libraryViewModel.nowPlaying) }
            } else if self.model.failed {
                LaunchErrorView()
            } else {
                LaunchLoadingView()
            }
        }
        .task { await self.model.bootstrap(appDelegate: self.appDelegate) }
    }
}

// MARK: - GraphContent

/// Renders a graph-backed window's content only once the object graph is ready.
/// These windows open on demand (post-launch), by which point the graph exists,
/// so the empty placeholder is effectively never shown. Keeping the windows
/// themselves unconditional lets `BocanApp.body` stay a flat scene list, which
/// the SwiftUI scene type-checker handles; gating whole scenes on `model.graph`
/// instead overran it.
struct GraphContent<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: (AppGraph) -> Content

    var body: some View {
        if let graph = model.graph {
            self.content(graph)
        } else {
            Color.clear
        }
    }
}

// MARK: - LaunchLoadingView

/// Minimal launch placeholder shown while the library database opens.
struct LaunchLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
            Text("Loading your library…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading your library")
    }
}

// MARK: - LaunchErrorView

/// Shown when the library database cannot be opened. The previous code crashed
/// (`fatalError`) here; surfacing the failure is friendlier and just as final.
struct LaunchErrorView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn’t open your library")
                .font(.headline)
            Text("Bòcan was unable to open its database. Please relaunch the app. "
                + "If the problem persists, restoring from a backup may be required.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
