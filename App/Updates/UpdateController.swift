import AppKit
import Observation

// TODO: remove @preconcurrency when Sparkle adds Sendable annotations
@preconcurrency import Sparkle

/// Wraps `SPUStandardUpdaterController` and exposes update actions to the menu.
///
/// Created once in `BocanApp.init()` and held as a `private let`. In release
/// builds the updater starts on launch, controlled by
/// `SUEnableAutomaticChecks` in Info.plist. Feed URL and automatic-update
/// preference are set via Info.plist keys; beta-channel overriding is
/// handled separately in issue #213.
///
/// Debug builds never start the updater. A debug build carries
/// `CFBundleVersion` 1, so every published release looks like an upgrade and
/// Sparkle nags at launch. Worse, the debug and installed apps share one
/// defaults container, so a stray "Skip This Version" click in a dev session
/// silences the installed app's automatic checks for that release too. The
/// "Check for Updates" menu item simply stays disabled in debug
/// (`canCheckForUpdates` never flips true).
///
/// `canCheckForUpdates` is a stored `@Observable` property updated via KVO so
/// the "Check for Updates…" button and menu item disable/enable reactively.
@Observable
@MainActor
final class UpdateController: NSObject {
    private let standardController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// `true` when Sparkle is ready to perform a user-initiated check.
    private(set) var canCheckForUpdates = false

    override init() {
        #if DEBUG
            let startsUpdater = false
        #else
            let startsUpdater = true
        #endif
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        // KVO-observe canCheckForUpdates on the Sparkle updater so the UI
        // reflects readiness without polling. The closure is called immediately
        // with .initial and again whenever the property changes.
        self.observation = self.standardController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Triggers the standard Sparkle "Check for Updates…" sheet.
    func checkForUpdates() {
        self.standardController.checkForUpdates(nil)
    }
}
