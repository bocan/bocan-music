import Observability
import SwiftUI

@main
struct BocanApp: App {
    private let log = AppLogger.make(.app)

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 600)
        .commands {
            // Phase 4 will populate the menu bar.
        }
    }

    init() {
        self.log.info("app.launched", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"])
        #if os(macOS)
            MetricKitListener.shared.start()
        #endif
    }
}
